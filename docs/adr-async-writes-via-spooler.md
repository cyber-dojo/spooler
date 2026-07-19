# ADR: Asynchronous writes via a spooler service

Status: Proposed

Date: 2026-07-15

## Context

Today web calls saver synchronously. In `run_tests` (web `app.rb`) web runs
the tests via runner, gets the traffic-light outcome, then calls
`saver.kata_ran_tests(...)` and blocks on it: the browser response carries the
saver-assigned `index` / `major_index` / `minor_index`, and any saver "Out of
order event" is mapped to `out_of_sync` (the mobbing dialog). So the light,
which is purely a runner fact, is nonetheless gated on a saver git commit, and
the write path and saver availability are on the browser's critical path.

We want four things:

1. All web writes to saver become asynchronous (non-blocking).
2. The traffic-light appears as soon as runner finishes, even if saver is
   completely down.
3. The strong guarantee is preserved: a solo user must never be falsely told
   they are mobbing.
4. A read/write split where reads may be eventually consistent (a lag of about
   5 seconds is acceptable), with storage optimised for writes.

Two facts about the current system shape the solution:

- The mobbing guarantee is a write-time property. saver appends an event with a
  `git update-ref` compare-and-swap and rejects a write whose intervening
  events carry a different `laptop_id` (saver `kata_v2.rb`). Reads already go
  via committed git state, not the working tree (saver `docs/reads-via-git.md`).
  So read consistency and the mobbing guarantee are already independent: this is
  effectively CQRS over an event-sourced store (`events.json` is the log).
- Deployment constraint. The services must run both on cyber-dojo.org (AWS) and
  as a standalone docker-only stack (the commander repo). In both, saver is the
  only stateful service: on AWS its data is a host_path bind mount to a
  single-host EBS directory (`/ebs_data/cyber-dojo/saver`); standalone it is a
  single `/cyber-dojo` volume. web has no durable disk in either deployment
  (stateless, ephemeral container filesystem). Any durable buffer therefore
  cannot live inside web, and must "rely only on a disk" so it is symmetric
  across both deployments.

## Decision

Introduce a new service, `spooler`: a durable, ordered, store-and-forward
outbox that sits between web and saver and owns its own disk volume (separate
from saver's `/cyber-dojo`).

The name follows the print/mail-spooler pattern: fast intake, a durable on-disk
buffer, and an in-order feed to a slower or sometimes-absent consumer (saver).

### 1. Event routing: ITE async, test sync-to-spooler

- Inter-test events (ITEs: file create / delete / rename / edit) are
  fire-and-forget from web to the spooler. web does not await them.
- Test events (ran_tests and friends) are synchronous to the spooler's durable
  ack. "Sync" means synchronous to the spooler (a fast on-disk append), NOT
  synchronous to saver's git commit.
- Both kinds flow through the one spooler, giving a single per-kata ordered
  channel.

This split matches the character of the two event kinds. ITEs are frequent,
cumulative (each save carries the full file set), and individually droppable.
Test events are infrequent, human-paced, and each is a distinct historical
traffic-light that supersession cannot reconstruct, so it earns durability on
write.

### 2. The traffic-light is a runner fact

web builds the light from runner's outcome and returns it immediately. It is
not gated on saver or on the spooler forwarding to saver. saver being down
becomes "the spooler has not drained yet", not "no light".

### 3. Ordering: (laptop_id, tab_id, tab_seq) and a reorder buffer

Arrival order at the spooler cannot be trusted: two fire-and-forget POSTs can
be reordered by the browser connection pool, proxies, or retries. So each event
is stamped by the browser with `(laptop_id, tab_id, tab_seq)`:

- `laptop_id` is the per-browser cookie, shared by every tab of one browser.
- `tab_id` is a random id the browser generates once per tab and holds for the
  tab's lifetime. It is needed because one `laptop_id` can drive more than one
  tab and each tab runs its own `tab_seq` from the same start; keyed on
  laptop_id and tab_seq alone, two tabs of one browser would collide and one
  tab's writes would be dropped as false duplicates of the other's. `tab_id`
  makes each tab a distinct ordered writer.
- `tab_seq` is that tab's own monotonic event counter - the true production
  order for that tab.

- The spooler keeps, per `(laptop_id, tab_id, kata)`, the next expected
  `tab_seq`. It releases events to saver in `tab_seq` order, buffering
  out-of-order arrivals until the gap fills.
- A `tab_seq` that never arrives within a bounded wait is skipped. Because
  test events are sync-acked (they cannot be silently lost), the only thing that
  can ever be a missing seq is a fire-and-forget ITE, which is superseded by the
  next event, so skipping it is always safe.
- `(laptop_id, tab_id, tab_seq)` doubles as the idempotency key: a redelivered or
  re-fired event with the same pair is a no-op at saver.

In-order forwarding is required even though files are cumulative: saver is
append-only, so committing a later event before an earlier one would leave HEAD
pointing at older file state, regressing the kata. Cumulative files make a
dropped event harmless; they do not make a reordered commit harmless.

### 4. Index is a browser prediction, reconciled; saver stays append-only

saver assigns the authoritative committed `index` at append time (head + 1, as
today). The browser predicts the index for immediate display (exactly what web
`app.rb`'s existing rescue path already does with `index + 1`) and reconciles it
to saver's committed value via the reconciliation read.

We do NOT make saver store-at-index or fill gaps. A v2 kata is an append-only
git commit chain with numeric tags; inserting a commit between two existing ones
would re-parent everything after it, changing shas and invalidating later tags,
i.e. rewriting history. Supersession (below) makes gap-filling unnecessary.

### 5. Detection moves to the read side: a stale-tab lock

The browser periodically reads saver's committed event stream (within the ~5s
eventual-consistency budget). It tracks `knownHead` - the highest event index it
has incorporated, set at page load and advanced as its own writes appear - and:

- locks the tab when the committed head has advanced beyond `knownHead`,
  disabling every action that would commit an event and showing a "refresh to
  continue" banner. A reload adopts the current head and clears the lock;
- recognises its own writes by `tab_id`, so its own lag never locks it: an event
  above `knownHead` bearing this tab's `tab_id` is its own write landing and
  advances `knownHead`, while an event that is not this tab's triggers the lock;
- words the banner from `laptop_id`: a different `laptop_id` is another laptop, a
  matching `laptop_id` with a different `tab_id` is another tab of the same
  browser;
- re-fires an own event that never landed (section 6).

This preserves the strong guarantee against a false lock. The committed stream is
monotonic and order-independent: once an event past my known head is committed it
stays committed, so a lagging read can only delay the lock (a false negative),
never invent one. Recognising my own writes by `tab_id` is what makes reacting to
the head moving safe: my own in-flight writes are not mistaken for another
writer, so my own lag - the cause of the original false positives - cannot
trigger the lock.

`tab_id` and `laptop_id` are concatenated into the single id saver already stores
per event, so the committed stream carries both for the read to split and saver
needs no new field. The full web-side design is
`web/docs/mobbing-stale-tab-lock.md`.

### 6. Loss handling

- A lost ITE that a later event has superseded is dropped by the browser (its
  file state is already in the later event).
- A lost ITE that was the tip (nothing landed after it) is re-fired, which is a
  plain append at head.
- A test event cannot be lost: it is sync-acked by the spooler and retried by
  the browser until acked.

### 7. Spooler storage: embedded SQLite (WAL)

The spooler persists its buffer in an embedded SQLite database (WAL mode) on its
own volume. This matches the house style (each cyber-dojo service is a small
HTTP service over one disk primitive; saver is Sinatra + git-on-disk, the
spooler is Sinatra + SQLite-on-disk), relies only on a disk, and behaves
identically on AWS and standalone. SQLite gives ordering (`tab_seq`),
idempotency (a unique constraint on `(laptop_id, tab_id, tab_seq)`), and crash-safe
durability (WAL fsync); WAL's reader/writer split matches the write-optimised,
eventually-consistent-read intent. Its single-writer model is the serialisation
point that lets saver shed its concurrency machinery.

### 8. Deployment and state continuity

The spooler is deployed exactly as saver is, because saver is the proven pattern
for a stateful cyber-dojo service and the spooler is deliberately its twin (a
small HTTP service over one on-disk primitive). saver's real deployment
(`saver/deployment/terraform`) has three properties the spooler copies:

- Singleton. saver's ECS service does not override `desired_count` (unlike the
  stateless web service, which sets `desired_count = var.desired_count` to scale
  to N tasks), so it runs as a single task. The spooler is likewise a singleton;
  its single-writer SQLite (section 7) requires it.
- State on the host, not in the container. saver's durable data is an ECS
  `host_path` bind mount from the EC2 host's EBS directory
  (`/ebs_data/cyber-dojo/saver`) to the container's `/cyber-dojo`. The container
  is disposable; the state is host-resident. The spooler mounts its own EBS
  host_path (separate from saver's) holding its SQLite database.
- Blue-green cutover. Production deploys are blue-green at the ECS-service level,
  orchestrated by the co-promotion pipeline (`aws-prod-co-promotion`), which
  promotes each service image from aws-beta to aws-prod and refuses to run while a
  blue-green deployment is already in progress. saver is in the promoted set, so it
  is deployed this way today with no unavailability window.

State continuity across a deploy therefore needs no export, snapshot, or migration
step: the replacement (green) task mounts the same host_path directory and opens
the same on-disk store the old (blue) task was using. For saver that is the git
repos; for the spooler it is the SQLite database and its WAL. This is the whole
mechanism by which the spooler's buffered-but-undrained events survive a spooler
upgrade: they are on the host disk, and the new version reads them on start and
resumes forwarding, deduplicated by `(laptop_id, tab_id, tab_seq)`.

The blue-green overlap window (green live and healthy before blue is drained) is
the only subtlety, and it is where the spooler's embedded SQLite is actually safer
than saver's git store. During the overlap both tasks have the volume mounted and
may write:

- saver removed all flock (per `saver/docs/reads-via-git.md`) and assumes a single
  writer; its overlap safety rests on the cutover being brief and one side
  draining.
- SQLite enforces a single writer itself, via OS file locks plus the WAL
  shared-memory (`-shm`) index. Two co-located processes cannot corrupt the
  database; the second writer blocks until the first commits. This holds only when
  blue and green are on the SAME host (POSIX advisory locks and the `-shm` mmap
  coordinate within one kernel, not across hosts), which the host_path model
  already forces: the EBS directory exists on exactly one host, so any task that
  can mount it is on that host.

Idempotency does double duty here. The `(laptop_id, tab_id, tab_seq)` key (section 7)
makes a redelivery a no-op at saver, which covers not only crash-replay but the
overlap case where blue and green both forward the same queued event to saver
during cutover.

Requirements this places on the spooler's terraform (mirroring saver):

- singleton: do not set `desired_count > 1`; the single-writer store forbids it;
- an EBS host_path bind mount for the SQLite database, separate from saver's
  `/cyber-dojo`;
- blue and green co-located on the volume's host, so green can mount the same
  host_path.

One item to confirm against the shared `ecs-service/v5` module (its source is an S3
zip, not in these repos, so it was not read): that it sequences a volumed service
as green-mounts-before-blue-unmounts (a true overlap), not
stop-blue-then-start-green. If the module stops the volumed blue task before
starting green (to avoid two tasks mounting one host_path), then a singleton
stateful service has a brief unavailability window on every deploy, and the
"seamless" claim above must be softened for both saver and the spooler. The
observed no-window behaviour of saver today is evidence for the overlap
sequencing, but the module is the authority.

### 9. Service structure: the sinatra-base Rack layout

The spooler mimics the code structure every other cyber-dojo Ruby service already
uses, taking saver as the template. All of these services derive from one base
Docker image (`ghcr.io/cyber-dojo/sinatra-base`) and share the same Rack layout
under `source/server/`, so the spooler is a new instance of a proven skeleton
rather than a fresh design.

The skeleton has two halves.

Boot and container (`config/`):

- `Dockerfile` pins `FROM ghcr.io/cyber-dojo/sinatra-base`, adds the
  service-specific packages, creates a dedicated non-root user, runs `tini` as
  PID 1, and starts `config/up.sh`.
- `config/up.sh` checks and prepares the mounted volume, then execs
  `puma --config=config/puma.rb` on the service port.
- `config/config.ru` is the Rackup file: `use Rack::Deflater`, optional Prometheus
  middleware, then `run App.new(Externals.new)`.
- `config/healthcheck.sh` and `config/puma.rb` complete the container contract.

The app (three collaborating classes):

- `App < AppBase` (`app.rb`) is a pure routing table: a list of
  `get_json(:collaborator, :method)` declarations (the probes) and `post_write`
  declarations (the nine write endpoints), each mapping one HTTP path to one action.
- `AppBase < Sinatra::Base` (`app_base.rb`) is the reusable base: it defines the
  `get_json` and `post_write` class macros that register the routes, parses the
  JSON request body, dispatches a GET through a single `json_result` method
  (`externals.public_send(collaborator).public_send(method, **args)`), and maps
  every exception to a status (400 RequestError, else 500) in one `error` block.
- `Externals` (`externals.rb`) is a lazily-memoized service locator: the single
  object injected into `App`, exposing each collaborator (`model`, `disk`, and so
  on) as a memoized accessor.

The spooler fills this skeleton with its own contents. Its `Externals` wires the
SQLite buffer (section 7), a sharded drainer, and a saver client in place of
saver's git-on-disk collaborators, and its `App` exposes saver's write API paths
(`kata_file_create` ... `kata_checked_out`) as durable-append endpoints: each
appends the write to the buffer and acks 200, and the drainer forwards to saver
asynchronously.

## Alternatives considered

Async queue embedded inside web.
  Rejected: web has no durable disk in the standalone stack (ephemeral
  filesystem, no volume). An in-memory queue would make writes best-effort and
  lose them on a web restart. Durability must live in a service that owns a disk.

A network broker (Kafka / Redpanda / AWS SQS FIFO / NATS / Redis).
  These are all viable durable queues, but a broker is a new stateful container
  with its own persistence to operate, which doubles the stateful surface of a
  standalone stack deliberately built around a single stateful service. SQS ties
  the design to AWS and breaks symmetry with the standalone deployment. If the
  spooler ever needed to scale across multiple hosts, NATS JetStream (file
  store, per-subject ordering, built-in dedup) or Valkey Streams would be the
  fallbacks, but that is not required for a single-host saver.

Store-at-index / gap-filling in saver.
  Rejected: git is append-only; inserting a commit rewrites history and
  invalidates later numeric tags. Supersession of cumulative ITEs makes it
  unnecessary.

Test events synchronous directly to saver.
  Rejected: it reintroduces saver's git-commit latency onto the test path and
  recouples the test flow to saver availability (breaking goals 1 and 2 for test
  events). It also creates two write paths (tests direct, ITEs via spooler): a
  sync test could commit at saver ahead of still-queued ITEs, so those stale
  pre-test ITEs would append after the test, leaving out-of-order events in the
  log. Routing everything through the one spooler keeps a single ordered channel.

Browser owns a binding index.
  Rejected in favour of predict-and-reconcile: saver cannot honour an arbitrary
  carried position in an append-only store, so the browser's index is a
  prediction that reconciliation corrects to saver's committed value.

## Consequences

- Goals met: writes are non-blocking; the light is a runner fact independent of
  saver; the mobbing guarantee holds as a read-side stale-tab lock that cannot
  false-lock (a tab recognises its own writes by `tab_id`); reads are eventually
  consistent.
- saver simplifies. With a single per-kata ordered source of writes and
  idempotency by `(laptop_id, tab_id, tab_seq)`, the `update-ref` compare-and-swap
  retry loop, the self-lag re-append, and the loser-rescue in
  saver `kata_v2.rb` have nothing left to do; saver reduces to an idempotent
  append, and the browser reads the committed stream (each event carrying its
  `laptop_id` and `tab_id`) to decide staleness for itself. This simplification is
  staged AFTER the spooler is proven, not before.
- New service to build and operate: `spooler`, plus its volume. The standalone
  stack goes from one stateful service to two.
- The diff-view click reads saver's lagging committed state, so it needs a
  materialisation spinner/poll for the brief window before an event is queryable
  at saver. Sync-to-spooler guarantees durability and order, not instant
  readability at saver.
- Residual loss window: an event lost in web's fire-and-forget dispatch before
  it reaches the spooler (much narrower than a saver outage). It is healed by
  the browser reconciliation read while the tab is open. A test event is not
  exposed to this window because it is sync-acked.

## Rollout

Expand/contract, in small steps. Each step below changes as few services as
possible (most change exactly one), is independently deployable and reversible,
and is behavior-neutral or strictly more-permissive unless its caveat says
otherwise. Where one step must precede another that is a sequencing dependency,
noted inline; it is not a reason to combine them into one deploy.

The sequence has two parts. Part A reaches asynchronous web->saver writes using
ONLY web and saver (no new service). Part B introduces the spooler to make those
writes durable and ordered. A short Bridge between them establishes the
`(laptop_id, tab_id, tab_seq)` idempotency key end-to-end (web + saver, still
no new service), pulling saver's dedup EXPAND forward so B4 becomes pure
contraction. Throughout, READS stay direct web->saver via committed git; nginx and
the other services are untouched.

Two facts from the code (`saver/source/server/model/kata_v2.rb`) shape Part A:

- saver never uses the client-sent `index` to POSITION an event. In `commit_event`
  it places at `head + 1` and stores that (`place_at`); the client `index` has one
  live role, the flat high-water mark for the write-time mobbing check (the
  `index .. head` foreign-`laptop_id` scan).
- web cannot compute a flat index locally, because a test commits one OR two events
  (the conditional `file_edit_before_test_event` runs first), which is why web
  re-sets its index from saver's synchronous return today. But web CAN compute
  `major` locally: `major` = count of light events (`is_light?` = colour not one of
  the four file events, `poly_filler.rb`). web does NOT need a local `minor`: a
  light is always at `major.0`, and any non-zero `minor` web displays (e.g. a
  checkout source event) comes from the events it reads, which already carry it.

So Part A moves detection to the read side (removing the client index's only role),
lets web own `major` locally, retires the now-dead client `index` from the write
path in an expand/contract, and only then makes the calls fire-and-forget.

### Part A - asynchronous writes with only web and saver

A0 (precondition, owned by the Option C rollout): laptop_id on committed events.
  Deploy Option C Phases 1-2 (`web/docs/mobbing-server-owned-index-design.md`):
  saver accepts and stores `laptop_id`, and does write-time dual-mode detection.
  Built, undeployed. Every step below assumes it is live.

A1 (web): read-side detection poll, additive.
  The browser periodically reads committed events (the read `edit.erb` already does
  on load, as a pollable endpoint) and, at this stage, flags `mobbing?` iff it sees
  a foreign `laptop_id`. saver KEEPS its write-time reject; the two agree and are
  belt-and-braces. Reversible by disabling the poll. This puts detection on the
  read side before any later step depends on it. This is the interim
  laptop-granularity form; the full stale-tab lock of section 5 needs `tab_id` to
  recognise a tab's own writes, so it lands once `tab_id` flows (B2).
  DONE (web): the read poll flags `mobbing?` on seeing a foreign `laptop_id`, and
  saver keeps its write-time reject so the two agree. This is the interim
  laptop-granularity form; the section-5 stale-tab lock waits on `tab_id` (B2).

A2 (web): resolve navigation targets from read data.
  revert already scans read events for the previous light but seeds the scan from
  `index - 2` (flat, `app.rb`); change it to find the previous light by `major`
  over the events it reads. checkout (`review.currentEvent()`) and diff
  (`was_index`/`now_index` per light) already come from read data. Also unify the
  light predicate: web's inclusion list (`app.rb` `light?`) vs saver's exclusion
  list (`poly_filler.rb` `is_light?`) agree today but would silently drift if a
  colour were added. Behavior-neutral; severs revert's last use of the flat client
  index.
  DONE (web): revert finds the previous light by `major` over the read events (no
  longer seeded from `index - 2`); checkout and diff already resolve from read data.
  The light predicate is unified, so web and saver no longer risk drifting if a
  colour is added. Behavior-neutral; revert's last use of the flat client index is
  severed.

A3 (saver): make the client `index` optional and unused.
  With detection on the read side (A1), saver's write-time `index .. head` check is
  redundant, so saver stops reading `index` (placement is already `head + 1`) AND
  gives the parameter a default so a request without it is accepted. This second
  half matters because saver's strict-kwarg dispatch 500s on a MISSING required
  keyword, so `index` must be optional before web can stop sending it. Still
  accepted if sent, just ignored. Strictly more-permissive: a stale index can no
  longer reject a write; the poll owns detection. Reversible by restoring the check.
  (Depends on A1.)
  DONE (saver): commit_event places unconditionally at head + 1; the write path has
  no index reject (behind, ahead, and no-laptop_id cases all removed), and a
  request may omit index (A6 below removes index from the dispatch entirely).

A4 (web): own `major` locally; stop depending on saver's returned index.
  Compute the displayed light number in the browser (`major += 1` on a light action;
  a light's `minor` is `0`) instead of from saver's return, reconciled by the A1
  poll and the page-load read. Stop re-setting a position from the response
  (`setIndex(light.index + 1)` etc). This is ADR section 4 ("browser prediction,
  reconciled") for `major`. Still synchronous, and web may still be sending `index`
  (ignored since A3) - that is removed next. (Depends on A2 for revert, and A3 so a
  stale or absent sent index cannot reject.)
  DONE (web): the browser owns `major_index` locally - seeded on page load from the
  last committed light (`setMajorIndex`) and incremented per live light action
  (`nextMajorIndex`, minor always `0`). The three live light paths (`[test]`,
  auto-revert, checkout) take the next major locally and no longer read a position
  from the write response. This went one step past the sketch above: a kata-page
  light carries NO trusted flat `index`. The flat index (needed only for review
  navigation and the diff tooltip) is resolved lazily on hover/click by reading the
  committed events and matching `major_index` (`cd.lib.getEvents`); a "ghost" (a
  light whose `major_index` is not among the committed lights - eg after a saver
  write that did not commit) gets no tooltip and a dead click. So the run_tests,
  auto_revert and checkout responses carry no position at all, and the run_tests
  rescue (saver down) fabricates nothing.

A5 (web): remove the `index` argument from all write POST calls.
  Now that saver ignores it (A3) and web does not depend on it (A4), web stops
  putting `index` in the nine event-write bodies. (Depends on A3, A4.)
  DONE (web): no write POST sends `index` - the `[test]` form's hidden `index` field
  is gone, the auto_revert and checkout POST bodies dropped it, and the file ITEs
  serialize a form that no longer contains it. With nothing left to send, the whole
  flat-index browser machinery was removed: `cd.kata.index`, `setIndex`, the hidden
  field, the page-load seed (`edit.erb`), and the file-ITE `setIndex` adoption. The
  `_index.erb` partial (now only the `majorIndex` code) was renamed `_major_index.erb`.
  Server-side, `source_event` dropped its dead `index`, and the `app.rb` `index`
  helper now serves only the two fork endpoints (which fork FROM a chosen index).
  The browser test harness was updated: its page-ready sync no longer reads the
  hidden field but polls `cd.mobbingPoll.knownHead`, and the obsolete
  index-advancement browser test was deleted. The only ITE structure trimmed was
  the dead `cd.interTestEventInProgress` getter; `waitForITE` serialization stays
  (it protects structural file ops from the saver's file-event CAS-loser drop until
  the spooler, Part B).

A6 (saver): remove the now-unused optional `index` parameter.
  With no client sending it (A5), drop `index` from the write method signatures and
  build the commit message from `place_at` instead of the client index. Contract
  step, after a soak so no old browser still sends it. (Depends on A5.)
  DONE (saver): the commit message is built from `place_at` (in `commit_on_main`,
  which now owns the position, yields it to the block, and returns it), and `index`
  is gone from every write method - the internal chain (`kata_v0/v1/v2` and the
  commit chain) AND the dispatch (`model.rb`). The HTTP boundary (`post_json`)
  strips a client-sent `index` for every write (the fork methods keep it), so
  saver's write contract has no index at all. This was decoupled from A5 and done
  ahead of it: A5 (web stops sending `index`) is now an independent web-side
  cleanup, not a saver dependency - web may keep sending `index` harmlessly
  (stripped at the boundary) until then. saver's own ruby client library
  (`source/client`) has also dropped `index` from its write calls, so the only
  remaining sender is web's browser POSTs.

A7 (web, OPTIONAL): make the saver write calls fire-and-forget.
  web no longer needs the return (A4), so ITE and test calls can dispatch without
  awaiting saver; the traffic-light comes from runner immediately. Independent of the
  A5/A6 field cleanup - it needs only A4. CAVEAT: without a durable buffer this is
  best-effort - a write lost in flight (web crash, saver down) is healed only by
  browser re-fire while the tab is open, and fire-and-forget ITEs can arrive at saver
  out of order (saver appends at head, so a reordered commit regresses file state).
  Ordering and durability are exactly what Part B adds. A conservative rollout may
  SKIP A7 and stay synchronous through Part A, gaining async together with
  durability at B3. (Depends on A4.)

At the end of Part A (through A6) web owns `major`, the client `index` is gone from
the write path, and detection is read-side - all with no new service. A7 buys
best-effort async; durable, ordered async is Part B.

### Bridge - establish the tab_seq idempotency key (web + saver, no spooler)

The idempotency key `(laptop_id, tab_id, tab_seq)` (sections 3, 7) can be put
end-to-end BEFORE the spooler is in the path, because saver already stores
`laptop_id` and `tab_id` (concatenated into the single per-event id, section 5) and
only lacks `tab_seq`. Landing the key here de-risks saver's contract change and
soaks web's stamping in production ahead of the spooler. It is the EXPAND half of
B4 pulled forward, leaving B4 as pure contraction. Reads stay direct web->saver.

A8 (saver): accept an optional `tab_seq` and dedup on the full key.
  saver takes an optional `tab_seq` argument (default, so old callers and the
  current path still work - mirroring A3's optional-first discipline) and adds an
  additive guard: a write whose `(laptop_id, tab_id, tab_seq)` is already
  committed is a no-op. The guard COMPOSES with saver's existing `update-ref`
  compare-and-swap; the CAS is NOT removed here (web still writes directly, so many
  tabs append concurrently and saver still needs it). Placement stays `head + 1`;
  `tab_seq` is an opaque dedup token saver only compares, never a position - it
  is not the old flat `index` A6 removed. Strictly additive. Deploy before A9.
  DONE (saver): every write method takes an optional `tab_seq` (default nil) - the
  dispatch (`model.rb`) and the internal chain (`kata_v0/v1/v2`) - so a caller that
  omits it still works. `commit_event` deduplicates: a write whose key is already
  committed returns the committed events unchanged (a no-op reporting the original
  position). The stored key is `(laptop_id, tab_seq, colour)`, which is the ADR's
  `(laptop_id, tab_id, tab_seq)` seen from saver - the browser's `tab_id` is folded
  into the single stored `laptop_id` (section 5) - plus `colour`. `colour` is in the
  key because one incoming write expands into two commits sharing one `tab_seq` (the
  implicit underneath `file_edit` and the real event); their differing colours stop
  the real event deduping against its own sibling on first delivery. The guard
  composes with the existing `update-ref` compare-and-swap, which is NOT removed (web
  still writes directly, so concurrent tabs still need it - that removal is B4).
  Placement stays `head + 1`; `tab_seq` is stored only so a later redelivery is
  recognised, never used as a position.

A9 (web): stamp `tab_id` + monotonic `tab_seq` and send it, synchronously.
  web generates a per-tab `tab_id` and that tab's monotonic `tab_seq`, and
  includes `tab_seq` in its write POSTs on the EXISTING direct-to-saver path.
  (This also introduces the `tab_id` the section-5 read-side stale-tab lock wants.)
  Writes stay SYNCHRONOUS - reorder protection is the spooler's job (B3), so going
  fire-and-forget now would let reordered direct writes regress file state. Direct
  to saver the A8 dedup catches only web's own re-fires (a modest win); the larger
  payoff, deduping spooler redelivery, is latent until Part B. (Depends on A8.)
  DONE (web): the browser owns a per-tab monotonic `tabSeq` (`_tab_seq.erb`),
  advanced once per write POST by `nextTabSeq` - not per committed event, so a
  `[test]` that commits two saver events (the underneath `file_edit` plus the light)
  is one POST carrying one `tab_seq`, matching saver's colour-keyed dedup (A8). The
  write POSTs send `tab_seq`: run_tests (`_run_tests.erb`), the file ITEs
  (`_file_inter_test_events.erb`), and checkout (`_checkout_button.erb`), and
  `saver_service.rb` forwards it on all nine write methods. `tab_id` itself already
  landed with the section-5 stale-tab lock (`cd.mobbingPoll.tabId` from
  `generateTabId`); the poll reads a committed event's tab_id as `laptop_id.slice(32)`,
  i.e. the browser folds `tab_id` into the stored `laptop_id`. Writes stay
  SYNCHRONOUS on the direct-to-saver path; fire-and-forget is A7/B3.

### Part B - the spooler (durable, ordered)

B1: insert the spooler as a transparent pass-through proxy.
  Stand up the spooler (its own EBS host_path volume, deployed as saver's stateful
  twin - see section 8), exposing saver's write API (`kata_file_create` ...
  `kata_checked_out`) and forwarding each call verbatim, including a 500. Repoint
  web's write client (`saver_service.rb`) from saver to the spooler; reads stay
  direct to saver. Byte-identical behavior (pure relay, no state). Reversible by
  repointing web back. Proves the new stateful service in the path with zero
  semantic change.
  DONE (spooler): the service exists as saver's structural twin (`sinatra-base`
  Rack app: `App` routing table, `AppBase`, `Externals`, `Prober`) and builds to
  an image with working alive/ready probes (section 9). The nine event writes
  (`kata_file_create` ... `kata_checked_out`) are exposed by a `post_pass_through`
  route macro; each request is forwarded to saver by `External::Saver` over the
  injectable `Externals#http` seam (`HttpJson::Requester`), and saver's response is
  relayed back verbatim - status, content-type, and body, including a 500. No state
  is persisted. The request body is forwarded byte-for-byte, including the `tab_seq`
  ordering field (saver, not the spooler, owns the write contract; saver's A8 dedup
  reads it). saver is located by
  `CYBER_DOJO_SAVER_HOSTNAME`/`CYBER_DOJO_SAVER_PORT`, as web's client already does.
  Non-event writes (`kata_create`, forks, `kata_option_set`, group ops) are not
  routed through the spooler; like reads they stay direct web->saver. Server-side
  tests mirror saver's harness and stub the http seam. The image now builds with
  the `sqlite3` gem (see B2), and the spooler has its `deployment/terraform`,
  limited so far to the ECR repository (`ecr.tf` and its org pull policy, plus
  main/data/versions/variables and the 244531986313 staging tfvars). That
  repository is created out-of-band by a one-time, manually-run `bootstrap-ecr`
  workflow that reuses `kosli-dev/tf`'s `apply.yml`, because `build-image` pushes
  the image before `deploy-to-beta` would otherwise create the repository. CI can
  now authenticate to AWS via OIDC: cyber-dojo enabled GitHub's immutable subject
  claims, so this new repo's token subject is `repo:cyber-dojo@<org-id>/spooler@<repo-id>:*`,
  and the `gh_actions_services` trust in `terraform-base-infra` was updated to
  match. NOT yet done: the ECS service that runs the spooler with its EBS
  host_path mount (section 8), deferred until that host volume exists, and
  repointing web's `saver_service.rb` (web-side) - so nothing yet sends live
  traffic through it.

B2: durable intake in the spooler (SQLite WAL), still synchronous forward.
  The spooler persists each write to its WAL log before forwarding, still
  synchronously returning saver's response. The `(laptop_id, tab_id, tab_seq)`
  key is already end-to-end from the Bridge (A8/A9), so here the spooler stores the
  arriving `tab_seq` as its ordering/idempotency column. The spooler already
  forwards `tab_seq` to saver verbatim (B1), so saver's A8 dedup keeps receiving the
  key when web is repointed at the spooler (B1b). Behavior unchanged; the buffer now
  exists and a crash replays un-acked forwards.
  DONE (spooler, groundwork only): the storage substrate this step needs is in
  place. The `sqlite3` gem is installed in the image (Alpine has no prebuilt gem,
  so it compiles its vendored SQLite amalgamation statically: the build toolchain
  goes in as a virtual apk package and is dropped again, leaving only libgcc at
  runtime), and `up.sh` checks and prepares a dedicated `/sqlite` volume - separate
  from saver's `/cyber-dojo` - refusing to start unless it is mounted and writable
  by the spooler user (the test `docker-compose.yml` mounts `/sqlite` as a tmpfs
  owned by the spooler uid, mirroring saver's owned-tmpfs `/cyber-dojo`, so the
  container boots for the test run). The spooler forwards `tab_seq` to saver
  verbatim in the write body (saver's A8 dedup owns it); the spooler does not yet
  persist or use it for ordering. The rest of the durable-intake logic (WAL
  persist-before-forward and the `(laptop_id, tab_id, tab_seq)` schema) is not
  yet written.
  PLAN (B2): the physical key. The spooler-bound write body carries no separate
  `tab_id` field: web folds it into `laptop_id` before forwarding (`web app.rb`
  `laptop_id` = `cookie[0,32] + tab_id`). So the conceptual `(laptop_id, tab_id,
  tab_seq)` key maps to the physical columns `(kata_id, laptop_id, tab_seq)`, where
  `laptop_id` already encodes `tab_id`. `colour` is NOT in the spooler key: saver
  needs colour because one write expands into two commits sharing a `tab_seq`, but
  the spooler's unit is the POST, and there is exactly one POST per `tab_seq`.
  PLAN (B2): removal is delete-on-ack. A buffered row is DELETED the moment saver
  acks it (2xx), so presence in the buffer means "undrained" and there is no
  `acked` column. This bounds the buffer to the live edge (matching the freshness
  note's "deleted after ack"). A write saver rejects with 500 stays in the buffer
  (undrained); in B2 (synchronous forward, no drainer) it is re-forwarded only
  when its writer retries the write (deduped to the same buffered row by its key).
  Draining a stuck backlog - on boot and continuously, retrying with backoff - is
  the B3 drainer, not B2.
  PLAN (B2): steps, each red-test first, behaviour staying synchronous throughout
  (no reorder buffer, skip-timeout, fire-and-forget, or background drainer - those
  are B3). B2 only inserts a durable buffer beneath the existing verbatim relay;
  draining that buffer (on boot and continuously) is B3.
    1. DB seam. Add an `External::Db` that opens the SQLite database on the
       `/sqlite` volume, sets WAL mode, and creates the `events` table if absent.
       Wire it into `Externals` behind an injectable path (mirroring the `http`
       seam) so tests open a temp or `:memory:` database.
    2. Persist-before-forward. A new `Spool` model inserts the row, THEN calls
       `saver.forward`, THEN DELETES the row on a 2xx (it is drained); the route
       macro calls `spool` instead of `saver` directly. saver's response is still
       relayed verbatim (the existing pass-through tests stay green).
    3. Persist survives a saver failure. When saver returns 500 the row stays in
       the buffer (undrained) and the 500 is still relayed verbatim.
    4. Idempotency column. Extract `kata_id`, `laptop_id`, `tab_seq` into columns
       under `UNIQUE(kata_id, laptop_id, tab_seq)`, inserting with `INSERT OR
       IGNORE`, so a redelivered write still in the buffer is a single row (a write
       already drained-and-deleted is instead deduped at saver by its A8 key).
    B2's scope is steps 1-4. Draining the buffer - on boot and continuously - is
    B3's drainer, so B2 has no boot-replay step of its own.
  DONE (spooler, steps 1-4 plus refinements): the durable buffer exists, every
  write is persisted before being forwarded, a row is drained on ack, and a
  redelivery still in the buffer is deduped.
  - DB seam (step 1). `External::Db` opens the SQLite database (default
    `/sqlite/spooler.db`), sets `PRAGMA journal_mode=WAL`, and creates the `events`
    table. It is wired into `Externals` behind an injectable seam (tests set the
    memoized `@db` via `instance_exec`, saver's house idiom) so a test can open a
    temp or in-memory database.
  - Persist-before-forward and delete-on-ack (steps 2 and 3). A `Spool` model
    persists the write (`Db#append` returns the row id), forwards it to saver, and
    on a 2xx deletes the row (`Db#delete`) so only undrained writes remain; a
    non-2xx (e.g. 500) leaves the row buffered for a later re-forward. saver's
    response is relayed verbatim, and the `post_pass_through` macro routes through
    `spool` (the model), which owns the forward to saver. There is no `acked`
    column: presence in the buffer is what "undrained" means.
  - busy_timeout. `External::Db` sets `PRAGMA busy_timeout=5000`. This is a genuine
    production setting, not a test scaffold: puma runs `workers Etc.nprocessors`, so
    one task has several worker PROCESSES each holding its own connection to the one
    file, and the blue-green overlap briefly adds a second task's connection. WAL
    serialises writers; busy_timeout makes a colliding writer wait rather than error
    SQLITE_BUSY - exactly the "second writer blocks" behaviour section 8 relies on.
  - Buffer scoped per kata. The `events` table carries a `kata_id` column and the
    reads are kata-scoped (`event_count(kata_id:)`, `events_for(kata_id:)`) because
    each kata is its own ordered log (the drainer will order per kata). `Spool`
    reads the kata id from the JSON body's `id`.
  - Idempotency key (step 4). `events` also carries `laptop_id` and `tab_seq`
    columns under `UNIQUE(kata_id, laptop_id, tab_seq)`, and `Spool` reads all
    three from the body. `append` is an UPSERT (`ON CONFLICT ... DO UPDATE ...
    RETURNING id`), so a redelivered write still in the buffer is deduped to one
    row and its original id is returned (so the right row is drained). NULL key
    parts stay distinct, so a write lacking a `tab_seq` is not deduped (it has no
    key). A write already drained-and-deleted is instead deduped at saver by its
    A8 key.
  - Non-JSON reject. A write whose body is not JSON is refused at intake with 400
    (`Spool` raises `RequestError`) and is neither persisted nor forwarded: an
    unparseable request can never become a valid saver write, so buffering it would
    leave a poison row that never drains (saver would 400 it anyway).
  - synchronous left at the SQLite default (FULL). A laptop benchmark put FULL's
    fsync-bound ceiling at ~13k-24k single-row commits/sec (NORMAL ~3-4x higher),
    far above expected load; but the laptop overstates FULL (macOS `fsync` is not
    the true barrier flush EBS does), and the single-volume fsync/IOPS rate, not the
    write lock, is the real ceiling. NORMAL is left as a documented knob to revisit
    against EBS if write throughput ever bites.
  - Tests. `Db0001-0006` exercise the real SQLite Db (open, WAL, busy_timeout, an
    append + kata-scoped read round-trip, append/delete of a buffered row, and
    dedup returning the original row's id); `Sp0001-0002` exercise `Spool` against a
    `DbAppendSpy` double (append recorded on a valid write; no append and a 400 on a
    non-JSON body), and `Sp0003-0005` against a real in-memory Db (a 2xx drains the
    row, a 500 leaves it buffered, a redelivery is deduped to one row). So the
    append/non-buffer assertions touch no real SQLite, while the drain/dedup
    assertions observe real buffer state; the shared file stays out of the test path.
  B2 is complete at steps 1-4; it has no remaining work. Draining the buffer (on
  boot and continuously) belongs to B3's drainer, so B2 has no boot-replay.
  Staged ahead for B3: the test compose runs a real
  `saver` (its `docker-compose` service, image pinned by versioner) that the
  spooler forwards to, ready for B3's drainer to be integration-tested end-to-end
  (write via the spooler, read the events back from saver).

B3: durable async via the spooler.
  ITE writes become fire-and-forget to the spooler's durable append; the spooler
  forwards in `tab_seq` order (reorder buffer; skip a never-arriving seq, safe
  because it can only be a superseded ITE). Test writes become synchronous to the
  spooler's durable ack (not saver's commit) and are retried until acked, so a test
  event is never lost - this UPGRADES A5's best-effort test writes to durable, and
  fixes A5's ITE-reordering. Idempotency `(laptop_id, tab_id, tab_seq)` makes redelivery
  a no-op. The diff-view read may briefly precede saver materialisation (spinner or
  poll, see Consequences). Gated on A1 (detection already read-side) and B2 (buffer
  proven).
  The drainer drains the buffer both at startup (rows a previous process left
  undrained) and continuously as writes arrive, retrying a failed forward with
  backoff (see Drainer parameter values); draining on boot is the drainer's job,
  not a step of its own. A real `saver` is already wired into the test compose
  (see B2 DONE) so the drainer can be integration-tested end-to-end.
  DESIGN (B3): intake and forwarding are separate concerns.
  - Intake. `Spool#write` appends the write to the buffer and returns an ack (a
    fast on-disk append), for both ITEs (fire-and-forget) and test events
    (sync-to-durable-ack). It does not forward to saver; the response the client
    sees is the spooler's ack, not saver's. Append, dedup and the JSON/400 reject
    stay here.
  - Forwarding. The drainer reads the buffer and forwards per `(kata_id, laptop_id)`
    in `tab_seq` order (laptop_id already encodes tab_id - there is no separate
    tab_id column), deletes each row saver acks (delete-on-ack), and retries a
    failed forward with backoff. Ordering uses an in-memory next-expected `tab_seq`
    per `(kata_id, laptop_id)`, held by the owning shard thread and seeded at first
    sight from the lowest buffered seq (delete-on-ack removes forwarded rows, so the
    buffer alone cannot tell a bottom gap from an already-forwarded prefix). The
    SQLite buffer plus that pointer IS the reorder buffer - there is no separate
    in-memory queue of rows; a gap is held until it fills or its held row's `enqueued_at`
    enqueue timestamp is older than the skip-timeout. The `Db` buffer is the only
    seam between intake and the drainer threads.
  - Determinism, without a do-nothing stub. The drainer is a standalone unit with
    an explicit `run`/`tick` entry point that `App`/`Externals` construction does
    NOT auto-start. Intake tests build the app with no drainer running, so buffer
    state is deterministic (nothing drains behind the test); drainer tests seed the
    buffer and drive `tick` directly. Auto-starting the drainer on construction, or
    putting it in the request path, is what would force a stub, so neither is done.
  - Sharded drainer threads in one process. The spooler runs as a single threaded
    process (not puma cluster mode). Draining is done by N drainer threads, each
    owning a shard of katas by `hash(kata_id) % N`; a kata is handled by exactly
    one thread, so within-kata `tab_seq` order holds by construction and no two
    threads ever forward the same kata - no lock, no shared drain state. Running in
    one process is what makes that partition well-defined; N worker PROCESSES would
    instead give one drainer per worker, all competing on the one buffer. Threaded
    intake suffices because a write is an I/O-bound SQLite append (the GVL is
    released during SQLite and the saver socket), so B3 changes
    `workers Etc.nprocessors` to threaded single mode. All threads - the intake
    threads and the drainer threads - share one SQLite connection. That is safe by
    documented guarantee (not just observation): libsqlite is built THREADSAFE=1
    (serialized) and the sqlite3 gem documents a `SQLite3::Database` as shareable
    across threads when `SQLite3.threadsafe?` is true. A prepared
    `SQLite3::Statement` is NOT shareable, so `External::Db` uses only the per-call
    `execute`/`get_first_value` (a transient statement per call), never a cached or
    shared prepared statement. The gem lock is held only for the fast
    SELECT/INSERT/DELETE, not the network forward, so different katas' forwards on
    different threads run in parallel and a forward never stalls another thread.
    busy_timeout covers the cross-process blue-green overlap. Per-thread
    connections are a deferred optimisation, not needed unless a bottleneck appears.
  PLAN (B3): steps, expand/contract so the drainer exists and is proven before
  intake stops forwarding (no window where nothing reaches saver). Each step is
  independently deployable, and every prerequisite is built before the step that
  needs it.
    0. Single-threaded spooler. `workers Etc.nprocessors` -> threaded single mode,
       keeping the one shared SQLite connection. Behaviour-neutral, reversible.
       DONE.
    1. Robust drain pass. `Drainer#drain` forwards buffered rows in order, deletes
       each on ack, rescues a failed forward, STOPS the pass on the first failure,
       and returns an ok/failing outcome for the loop to act on.
    2. Enqueue timestamp + clock. Add a `enqueued_at` column and an injectable time seam;
       intake stamps `enqueued_at` on append. Behaviour-neutral (unused until step 3), but a
       prerequisite: skip-timeout has nothing to measure against without `enqueued_at`.
    3. Ordered drain pass. Forward per `(kata_id, laptop_id)` in `tab_seq` order
       using an in-memory next-expected pointer (seeded at first sight from the
       lowest buffered seq); hold a gap and skip it once the held row's `enqueued_at` is
       older than the skip-timeout (5s). Single Drainer; inert in production until
       arrivals can be out of order (step 7).
    4. Drain loop. Repeat drain, sleeping the poll-interval (250ms) when healthy or
       the failure backoff (250ms doubling to the 10s cap) chosen from the pass
       outcome. An injectable sleeper and a stop-after-N hook keep it testable;
       no threads yet.
    5. Shard the drainer. `Drainer.shard_of` (a stable CRC32, not String#hash)
       assigns each kata to one of N worker Drainers; a DrainerPool runs each in a
       background thread over its shard, with graceful stop. A concurrency stress
       test drains many katas x events across N threads and asserts every event
       reaches saver exactly once and per-`(kata_id, laptop_id)` `tab_seq` order
       holds. The pool is built and stress-tested here; it is started at boot in
       step 6, paired with the intake flip. Still additive: intake forwards
       synchronously, so the pool only retries rows a synchronous forward stranded.
    6. Intake append-only (contract), and start the pool at boot. `Spool#write`
       appends (stamping `enqueued_at`) and returns a bare 200 ack, dropping the
       synchronous forward+delete; the DrainerPool, started at boot, is the sole
       forwarder. saver's response no longer flows back through a write (web
       already ignores it, A4/A5). The B1 relay tests are removed (the relay no
       longer exists); every remaining test uses an isolated db (a spy, an
       in-memory, or a temp file), so a boot-started pool has no shared test
       buffer to drain behind.
    7. web (separate repo). Make test writes synchronous to the spooler's ack and
       retried until acked FIRST (or in the same deploy), THEN make ITE writes
       fire-and-forget; add the diff-view materialisation spinner/poll. Reordering
       becomes possible and test events become durable together here, so the
       skip-timeout invariant (a missing seq is only ever a superseded ITE) holds
       the moment skipping can occur.
  DONE (spooler, steps 0-6): the durable async write path is complete on the
  spooler side.
  - Intake. `Spool#write` appends the write to the SQLite buffer (stamping
    `enqueued_at` from the injectable clock) and the `post_write` route acks 200 -
    no saver call. A non-JSON body is refused with 400 before anything is buffered.
  - Drainer. A `DrainerPool` of N sharded worker threads (`Drainer.shard_of`,
    CRC32), started at boot in `config.ru`, forwards buffered writes to saver: per
    writer `(kata_id, laptop_id)` in `tab_seq` order via an in-memory next-expected
    pointer (seeded at first sight), holding a gap and skipping it once it ages past
    `SKIP_TIMEOUT_MS`, dropping a late below-expected seq, deleting each row on ack,
    and retrying a failed forward with a `Backoff` (`POLL_INTERVAL_MS` base doubling
    to `BACKOFF_CAP_MS`). Starting drains any rows a previous process left undrained
    (crash recovery); it then runs continuously.
  - One process (step 0). puma runs one threaded process, so the shared SQLite
    connection is gem-serialised (THREADSAFE=1) and the drainer is a fixed set of
    in-process threads.
  - Tested. Db (open/WAL/busy_timeout, append/read/delete/dedup/enqueued_at); Sp
    (append + ack + not-forwarded, non-JSON 400, dedup, all endpoints); Dn (ordered
    drain, skip-timeout, drop-late, backoff loop, shard partition); Bk (backoff);
    Dp (a concurrency stress test: many katas x events x N threads deliver every
    write exactly once, each kata in tab_seq order).
  NOT yet done: step 7 (web-side fire-and-forget ITEs + diff-view materialisation,
  separate repo); the spooler's ECS service and EBS mount (deployment, see B1); and
  a client-side integration test (write via the spooler -> drainer -> read back
  from the compose saver).

B4: simplify saver to an idempotent append (contract).
  The dedup guard already exists from A8; with the spooler now the single ordered
  writer, saver's `update-ref` compare-and-swap retry, self-lag re-append, and
  loser-rescue have nothing left to do and are REMOVED, leaving an idempotent
  append. The poll reads the committed stream (each event's `laptop_id` and
  `tab_id`) to decide staleness itself. This is the CONTRACT half whose EXPAND was
  pulled forward to A8; keep the dedup in place while removing the reject path, so
  no window double-appends or falsely refuses. Deploy last, after the spooler is
  proven.

## Drainer parameter values

Both knobs below bound the queue dwell (enqueue to forward) and are sized
against the ~5s read eventual-consistency budget. They are injected config; the
values here are the defaults. The dominant scenario that sets the budget is a
group kata: many participants write events for ~30 min then stop, after which a
dashboard session reads from saver (an instructor often also watches the
dashboard live during the active window, which is what motivates the freshness
and anomaly API below).

Decided:

- backoff-cap = 10s. When a forward to saver fails, the drainer retries with
  exponential backoff capped at 10s, indefinitely (a queued write, especially a
  sync-acked test event, is never dropped). The cap bounds the post-recovery
  pickup delay: once saver is healthy again a held row drains within one cap
  interval. A long outage therefore blows the 5s FRESHNESS budget (a reader
  briefly sees stale state) but never loses the write - freshness is bounded by
  the budget, durability is unconditional.
- skip-timeout = 5s. The reorder buffer holds an out-of-order event waiting for a
  missing `tab_seq`; if the gap has not filled within 5s the drainer releases
  past it. Out-of-order arrivals are expected to be rare, and waiting 5s for that
  rare case is acceptable. The skip only ever discards an ITE (a test event is
  sync-acked, so it can never be the missing seq) and a dropped ITE is harmless
  because the next event's cumulative file set supersedes it.
- poll-interval = 250ms. After the drainer drains the buffer (or finds it empty)
  with saver healthy, it sleeps this long before the next pass, and it is the base
  the failure backoff doubles from up to backoff-cap. It bounds drainer-primary
  delivery latency (a write reaches saver within ~250ms plus the forward), well
  inside the 5s freshness budget, and costs ~4 empty reads/sec when idle. A signal
  from intake could replace the poll later (both share one process), but the poll
  meets the budget without the coordination.

Recommended but not yet pinned: backoff jitter; and treating a genuine 4xx
contract error as park/dead-letter rather than retry-forever, so one poison row
cannot wedge the ordered channel while transient 5xx/timeout/
connection-refused failures still retry.

## Open questions

- Is production web a single instance or several? It does not affect correctness
  here but should be recorded.
- The reconciliation read cadence and the `last_seen` semantics. This ties to
  the server-owned-index direction already chosen in web
  (`web/docs/mobbing-server-owned-index-design.md`, "Option C").
- Whether the spooler should return a synchronous staleness verdict for test
  events (a cheap head check on the sync-acked path), restoring instant
  test-time detection while ITEs stay read-side.
- Drainer shard count N vs peak write rate. Draining is sharded across N threads
  (`hash(kata_id) % N`), so different katas forward in parallel (up to N at once)
  while each kata stays ordered - matching, not serialising below, today's direct
  web->saver cross-kata parallelism. The open question is sizing N against saver's
  forward latency (a localhost round-trip plus saver's in-process git commit) and
  peak aggregate write rate, and whether N-way is enough under a large group-kata
  burst. A shortfall degrades freshness (a backlog forms, writes land late) but
  never durability (they still land). If N threads on one host are not enough, the
  next step is multiple hosts - the NATS/Valkey fallback in Alternatives
  considered. Measure saver forward latency against realistic peak load to pick N.

## Future work: a freshness and anomaly API

Not part of the write path; a deferred, additive read-only endpoint (per
kata-id) that the dashboard can poll quietly. It is safe to add after the
spooler is proven because it cannot affect ordering, the eventual-consistency
budget, or correctness: it only observes.

The governing constraint is what makes this the spooler's job rather than
saver's. The spooler holds only the LIVE EDGE: undrained plus very recently
acked rows, deleted after ack. It is therefore a freshness/anomaly lens, NOT an
analytics store. The full history (every committed light over the session) is
saver's committed stream, which the dashboard already reads. The two are
complementary: saver answers "what happened", the spooler answers "how current
is what I am seeing, and is anything stuck".

Freshness (per kata-id):

- backlog depth: rows queued but not yet acked by saver.
- drain lag: age of the oldest undrained row (enqueued_at to now).
- drainer-in-backoff: whether saver is currently unreachable (the drainer is
  retrying under the backoff-cap).

Anomalies (things only the spooler can see, because it is the single ordered
choke point):

- events currently held in the reorder buffer (out of order right now).
- count of skipped (lost) ITEs.

The single win: it lets a dashboard distinguish "the room went quiet" from "the
pipe is backed up". Watching saver alone, an instructor sees "no new lights" and
cannot tell whether the group stopped working or saver is lagging behind a
healthy spooler backlog. The freshness numbers answer that directly.

Per-participant liveness (a roster of active (laptop_id, tab_id) with last-write
heartbeats) was considered and set aside: it needs richer dashboard UI and is
not the value here. Freshness and anomalies are.

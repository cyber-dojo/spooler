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

### 3. Ordering: (laptop_id, tab_id, client_seq) and a reorder buffer

Arrival order at the spooler cannot be trusted: two fire-and-forget POSTs can
be reordered by the browser connection pool, proxies, or retries. So each event
is stamped by the browser with `(laptop_id, tab_id, client_seq)`:

- `laptop_id` is the per-browser cookie, shared by every tab of one browser.
- `tab_id` is a random id the browser generates once per tab and holds for the
  tab's lifetime. It is needed because one `laptop_id` can drive more than one
  tab and each tab runs its own `client_seq` from the same start; keyed on
  laptop_id and client_seq alone, two tabs of one browser would collide and one
  tab's writes would be dropped as false duplicates of the other's. `tab_id`
  makes each tab a distinct ordered writer.
- `client_seq` is that tab's own monotonic event counter - the true production
  order for that tab.

- The spooler keeps, per `(laptop_id, tab_id, kata)`, the next expected
  `client_seq`. It releases events to saver in `client_seq` order, buffering
  out-of-order arrivals until the gap fills.
- A `client_seq` that never arrives within a bounded wait is skipped. Because
  test events are sync-acked (they cannot be silently lost), the only thing that
  can ever be a missing seq is a fire-and-forget ITE, which is superseded by the
  next event, so skipping it is always safe.
- `(laptop_id, tab_id, client_seq)` doubles as the idempotency key: a redelivered or
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
identically on AWS and standalone. SQLite gives ordering (`client_seq`),
idempotency (a unique constraint on `(laptop_id, tab_id, client_seq)`), and crash-safe
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
resumes forwarding, deduplicated by `(laptop_id, tab_id, client_seq)`.

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

Idempotency does double duty here. The `(laptop_id, tab_id, client_seq)` key (section 7)
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

- `App < AppBase` (`app.rb`) is a pure routing table. Its whole body is a list of
  `get_json(:collaborator, :method)` / `post_json(:collaborator, :method)`
  declarations, each mapping one HTTP path to one `(collaborator, method)` pair.
- `AppBase < Sinatra::Base` (`app_base.rb`) is the reusable base: it defines the
  `get_json`/`post_json` class macros that register the routes, parses the JSON
  request body, dispatches through a single `json_result` method
  (`externals.public_send(collaborator).public_send(method, **args)`), and maps
  every exception to a uniform status (400 RequestError, 505 NoLongerImplemented,
  500 otherwise) in one `error` block.
- `Externals` (`externals.rb`) is a lazily-memoized service locator: the single
  object injected into `App`, exposing each collaborator (`model`, `disk`, and so
  on) as a memoized accessor.

The spooler fills this skeleton with its own contents. Its `Externals` wires a
SQLite-backed model (section 7) and a saver-forwarder in place of saver's
git-on-disk collaborators, and its `App` exposes saver's write API paths
(`kata_file_create` ... `kata_checked_out`), which is exactly what B1 stands up as
a transparent pass-through before the durable buffer is added.

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
  idempotency by `(laptop_id, tab_id, client_seq)`, the `update-ref` compare-and-swap
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
writes durable and ordered. Throughout, READS stay direct web->saver via committed
git; nginx and the other services are untouched.

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

A2 (web): resolve navigation targets from read data.
  revert already scans read events for the previous light but seeds the scan from
  `index - 2` (flat, `app.rb`); change it to find the previous light by `major`
  over the events it reads. checkout (`review.currentEvent()`) and diff
  (`was_index`/`now_index` per light) already come from read data. Also unify the
  light predicate: web's inclusion list (`app.rb` `light?`) vs saver's exclusion
  list (`poly_filler.rb` `is_light?`) agree today but would silently drift if a
  colour were added. Behavior-neutral; severs revert's last use of the flat client
  index.

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
  route macro and relayed to saver verbatim - status, content-type, and body,
  including a 500 - by `External::Saver` over the injectable `Externals#http` seam
  (`HttpJson::Requester`); pure relay, no state. saver is located by
  `CYBER_DOJO_SAVER_HOSTNAME`/`CYBER_DOJO_SAVER_PORT`, as web's client already does.
  Non-event writes (`kata_create`, forks, `kata_option_set`, group ops) are not
  routed through the spooler; like reads they stay direct web->saver. Server-side
  tests mirror saver's harness and stub the http seam. NOT yet done: repointing
  web's `saver_service.rb` (web-side), and the spooler's EBS host_path volume and
  deployment terraform (section 8) - so nothing yet sends live traffic through it.

B2: durable intake in the spooler (SQLite WAL), still synchronous forward.
  The spooler persists each write to its WAL log before forwarding, still
  synchronously returning saver's response. Introduce `(laptop_id, tab_id, client_seq)`:
  the spooler accepts an optional `client_seq` (ignored if absent), then web stamps
  each event with its `tab_id` and that tab's monotonic `client_seq`. Behavior
  unchanged; the
  buffer now exists and a crash replays un-acked forwards. Deploy the spooler side
  (accept) before the web side (send).

B3: durable async via the spooler.
  ITE writes become fire-and-forget to the spooler's durable append; the spooler
  forwards in `client_seq` order (reorder buffer; skip a never-arriving seq, safe
  because it can only be a superseded ITE). Test writes become synchronous to the
  spooler's durable ack (not saver's commit) and are retried until acked, so a test
  event is never lost - this UPGRADES A5's best-effort test writes to durable, and
  fixes A5's ITE-reordering. Idempotency `(laptop_id, tab_id, client_seq)` makes redelivery
  a no-op. The diff-view read may briefly precede saver materialisation (spinner or
  poll, see Consequences). Gated on A1 (detection already read-side) and B2 (buffer
  proven).

B4: simplify saver to an idempotent append (contract).
  With the spooler the single ordered writer and idempotency by
  `(laptop_id, tab_id, client_seq)`, saver's `update-ref` compare-and-swap retry, self-lag
  re-append, and loser-rescue have nothing to do; saver contracts to an idempotent
  append, the poll reading the committed stream (each event's `laptop_id` and
  `tab_id`) to decide staleness itself. Add the dedup before removing the reject
  path, so no window double-appends or falsely refuses. Deploy last, after the
  spooler is proven.

## Open questions

- Is production web a single instance or several? It does not affect correctness
  here but should be recorded.
- The reconciliation read cadence and the `last_seen` semantics. This ties to
  the server-owned-index direction already chosen in web
  (`web/docs/mobbing-server-owned-index-design.md`, "Option C").
- Whether the spooler should return a synchronous staleness verdict for test
  events (a cheap head check on the sync-acked path), restoring instant
  test-time detection while ITEs stay read-side.

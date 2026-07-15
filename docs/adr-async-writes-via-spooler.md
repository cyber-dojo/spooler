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
3. saver keeps its strong guarantee of never raising a false-positive
   `mobbing?` dialog (a solo user must never be told they are mobbing).
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

### 3. Ordering: (laptop_id, client_seq) and a reorder buffer

Arrival order at the spooler cannot be trusted: two fire-and-forget POSTs can
be reordered by the browser connection pool, proxies, or retries. So each event
is stamped by the browser with `(laptop_id, client_seq)`, where `client_seq` is
the browser's own per-laptop monotonic event counter (the true production
order).

- The spooler keeps, per `(laptop_id, kata)`, the next expected `client_seq`. It
  releases events to saver in `client_seq` order, buffering out-of-order
  arrivals until the gap fills.
- A `client_seq` that never arrives within a bounded wait is skipped. Because
  test events are sync-acked (they cannot be silently lost), the only thing that
  can ever be a missing seq is a fire-and-forget ITE, which is superseded by the
  next event, so skipping it is always safe.
- `(laptop_id, client_seq)` doubles as the idempotency key: a redelivered or
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

### 5. Mobbing detection moves to the read side, gated only on foreign laptop_id

The browser periodically reads saver's committed event stream (within the ~5s
eventual-consistency budget) and:

- shows the `mobbing?` dialog if and only if it sees an event whose `laptop_id`
  differs from its own;
- marks its own events confirmed when their `(laptop_id, client_seq)` appears;
- heals its own events that never landed (see below).

Gating the dialog solely on the presence of a foreign `laptop_id` is what
preserves the strong guarantee. Foreign-laptop presence is monotonic and
order-independent: once committed it stays committed, and a lagging read can
only hide it briefly (a false negative), never invent it (a false positive). An
index falling behind, by contrast, is exactly what caused the original false
positives, so it is deliberately not a trigger.

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
idempotency (a unique constraint on `(laptop_id, client_seq)`), and crash-safe
durability (WAL fsync); WAL's reader/writer split matches the write-optimised,
eventually-consistent-read intent. Its single-writer model is the serialisation
point that lets saver shed its concurrency machinery.

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
  saver; the mobbing guarantee holds as a read-side laptop_id decision that
  cannot false-positive; reads are eventually consistent.
- saver simplifies. With a single per-kata ordered source of writes and
  idempotency by `(laptop_id, client_seq)`, the `update-ref` compare-and-swap
  retry loop, the self-lag re-append, and the loser-rescue in
  saver `kata_v2.rb` have nothing left to do; saver reduces to an idempotent
  append plus recording a foreign-laptop collision for the browser to read back.
  This simplification is staged AFTER the spooler is proven, not before.
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

## Open questions

- Is production web a single instance or several? It does not affect correctness
  here but should be recorded.
- The reconciliation read cadence and the `last_seen` semantics. This ties to
  the server-owned-index direction already chosen in web
  (`web/docs/mobbing-server-owned-index-design.md`, "Option C").
- Whether the spooler should return a synchronous mobbing verdict for test
  events (a cheap head check on the sync-acked path), restoring instant
  test-time detection while ITEs stay read-side.

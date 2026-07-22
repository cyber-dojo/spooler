# Future enhancements: asynchronous writes via a spooler

Deferred, additive enhancements to the design in `adr-async-writes-via-spooler.md`.
Each is independent and can land after the spooler is proven; none is on the
critical path. The ADR describes the shipped design (fire-and-forget delivery);
this document collects the work deliberately left out of it.

## Guaranteed delivery to saver

The drainer is fire-and-forget: it forwards each buffered write to saver once, in
`tab_seq` order per writer, and deletes the row as it sends it without reading
saver's response. A forward lost while saver is unavailable, or rejected by saver,
is not retried and is lost. Intake stays durable (a test event is sync-acked onto
the WAL buffer before web continues); only delivery onward to saver is
best-effort.

Guaranteeing delivery means the drainer stops ignoring saver's response and keeps
each row until saver acknowledges it:

- Delete-on-ack, not delete-on-send. Read saver's response; delete the row only on
  a success (2xx). A non-2xx, or a forward that raises, leaves the row buffered.
- Retry transient failures with backoff. A saver outage (connection refused,
  timeout, 5xx) is retried, backing the drain loop off (exponential, capped) so a
  long outage does not busy-loop. The cap bounds post-recovery pickup latency (a
  held row drains within one cap interval once saver is healthy).
- Isolate a stalled writer. A per-writer outcome (progressed / failed / idle) lets
  one writer stall - a gap it is holding, or a write saver keeps rejecting -
  without wedging the other writers in its shard, and lets the loop back off only
  when nothing got through across the board.
- Dead-letter a permanent rejection. A write saver will NEVER accept (eg one for a
  kata that does not exist) must be parked, not retried forever. This needs a saver
  contract change: saver must return a genuine 4xx for such a write (it 500s
  today), so the drainer can tell a permanent rejection (park it) from a transient
  5xx / timeout / connection-refused (keep retrying).

Design notes for whoever picks this up:

- A held reorder gap must NOT count as a delivery failure. When the outcome
  distinction returns, a writer holding a non-skippable gap (waiting for a missing
  lower `tab_seq`) must report `idle`, not `failed` - otherwise a pure reorder gap
  triggers the failure backoff and a shard waiting only on an in-flight seq reacts
  a backoff interval late. Only a real forward failure (non-2xx or raise) is
  `failed`. (This was an actual bug in the pre-fire-and-forget code; do not
  reintroduce it.)
- A prior implementation of all of the above existed before the fire-and-forget
  simplification and can be recovered from git history rather than rederived:
  `source/server/backoff.rb` (the `Backoff` class), the drainer's `drained?` ack
  check and its progressed/failed/idle `drain_writer` outcomes, the `run` loop's
  backoff, and the matching tests (`test/server/backoff.rb`, the drainer test's
  backoff-loop / failure / poison-rejection cases, and the `saver_http_raises`
  double). The `SaverResponseStub` and `SaverHttpStub` success doubles stay in the
  suite (the surviving ordering tests forward through them).
- The reorder buffer, skip-timeout, per-writer `tab_seq` ordering, and sharding are
  NOT part of this enhancement - they survive the fire-and-forget simplification
  and stay in place. Only the response-checking, retry, backoff, and per-writer
  outcome logic are removed by it.
- Backoff jitter is worth adding when the backoff returns, to spread retries when
  many shards recover from a saver outage at once.

This is the enhancement that restores the delivery durability the fire-and-forget
drainer gives up; the two below are smaller UI/robustness refinements.

## Browser re-fire of test writes until acked

A test write is synchronous to the spooler's ack (web awaits it) but is NOT
re-fired if the POST is lost in flight before that ack - the same narrow
best-effort window the old direct web->saver write always had, healed by the
browser's reconciliation read. Re-firing until the spooler acks would make a test
event unloseable at intake and restore the strong skip-timeout invariant (a
missing seq is then only ever a superseded ITE). Left out for now as over-design:
the direct-to-saver write it replaces never re-fired either, and the residual
window is narrow and self-healing. This closes only the pre-intake-ack window; the
post-ack forward window is closed by Guaranteed delivery above.

## Diff-view materialisation spinner/poll

When a light's diff is clicked in the brief window before its event has drained to
saver, the diff does not work yet. A spinner or short poll could smooth that
window. Left out for now as over-design: before the spooler a light that never got
saved simply had no working diff, so a not-yet-materialised diff is no worse than
the old behaviour.

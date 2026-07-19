#!/usr/bin/env puma

environment 'production'
rackup "#{__dir__}/config.ru"

# The spooler is a singleton (ADR section 8): its embedded SQLite store is
# single-writer, so the service runs as one task - and as one process, so its
# in-process drainer is a single background thread. Intake concurrency comes from
# threads, not worker processes; all threads share one SQLite connection and the
# sqlite3 gem serialises access to it. The pool only overlaps requests parked on
# a (synchronous) saver forward, so a small fixed size, unrelated to core count,
# is enough.

threads 0, 16

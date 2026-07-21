require 'zlib'
require_relative 'backoff'

class Drainer

  # A gap (a missing tab_seq below a higher buffered seq) is held this long,
  # measured from the held row's enqueued_at, before the drainer gives up and
  # releases past it. Only ever a superseded ITE is skipped (a test event is
  # sync-acked, so it can never be the missing seq).
  SKIP_TIMEOUT_MS = 5000

  # The drain loop sleeps this long between passes when healthy; it is also the
  # base the failure backoff doubles from, up to BACKOFF_CAP_MS.
  POLL_INTERVAL_MS = 250
  BACKOFF_CAP_MS = 10_000

  def self.shard_of(kata_id, shard_count)
    # The drainer-worker index (0...shard_count) that owns this kata. A stable
    # hash (not String#hash, which is per-process random) so a kata maps to the
    # same shard across workers; a re-seed after a restart is safe regardless.
    Zlib.crc32(kata_id) % shard_count
  end

  def initialize(externals, shard_index: 0, shard_count: 1)
    # externals is the service locator (db, saver, time). This worker drains the
    # katas whose shard_of is shard_index; the default single shard drains all.
    # next_expected is the per-writer reorder pointer (see drain).
    @externals = externals
    @shard_index = shard_index
    @shard_count = shard_count
    @next_expected = {}
  end

  def drain
    # Forward buffered writes to saver, grouped by writer (kata_id, laptop_id)
    # and released in tab_seq order per writer, deleting each one saver acks
    # (delete-on-ack). Writers are independent: a gap in one, OR a write saver
    # rejects (a reachable saver returning a non-2xx - eg a poison write for a
    # kata that does not exist), stalls only that writer; every other writer still
    # drains, so one poison write cannot wedge the whole shard. A rejected write
    # stays buffered and is retried on a later pass (it is never lost).
    #
    # Return false (so the loop backs off) only when the pass tried to forward and
    # nothing got through - saver unreachable or failing across the board. If any
    # writer made progress, a stuck writer is just one poison kata and the healthy
    # writers must not be slowed by a backoff.
    mine = @externals.db.buffered_events.select { |event| mine?(event['kata_id']) }
    by_writer = mine.group_by { |event| [event['kata_id'], event['laptop_id']] }
    outcomes = by_writer.map do |writer, events|
      drain_writer(writer, events.sort_by { |event| event['tab_seq'] })
    end
    !(outcomes.include?(:failed) && !outcomes.include?(:progressed))
  end

  def run(sleeper: ->(ms) { sleep(ms / 1000.0) })
    # Loop: drain, then sleep the delay the backoff chooses from the pass outcome
    # (the poll interval when healthy, doubling to the cap while saver fails),
    # until stop is called. The sleeper is injectable so tests drive the loop
    # without real sleeping; it is passed milliseconds.
    @running = true
    backoff = Backoff.new(base_ms: POLL_INTERVAL_MS, cap_ms: BACKOFF_CAP_MS)
    sleeper.call(backoff.next_ms(ok: drain)) while @running
  end

  def stop
    # Ask the run loop to exit after its current pass.
    @running = false
  end

  private

  def mine?(kata_id)
    # Whether this worker's shard owns the kata.
    self.class.shard_of(kata_id, @shard_count) == @shard_index
  end

  def drain_writer(writer, events)
    # events are this writer's buffered rows, tab_seq ascending. Release them in
    # tab_seq order from next_expected, seeded at first sight from the lowest
    # buffered seq (delete-on-ack removes forwarded rows, so the buffer alone
    # cannot distinguish an already-forwarded prefix from a bottom gap). A row
    # above next_expected is a gap: hold it (and the rest) for a later pass,
    # unless it has aged past the skip-timeout, in which case skip the missing
    # seq and release from here. A row below next_expected is already past - a
    # skipped seq arriving late, or a redelivery of a drained one - so drop it
    # (delete unsent) rather than forward it out of order; saver already has, or
    # will never get, that seq. A forward that saver does not ack (a non-2xx, or a
    # raise - saver unreachable) stops THIS writer here, leaving that row and the
    # rest buffered for a later pass (order is preserved: a later seq is never
    # forwarded before an unacked earlier one).
    #
    # Returns :progressed if it forwarded at least one row, :failed if it hit a
    # forward failure before forwarding anything, and :idle if it neither forwarded
    # nor failed (held a gap, dropped a stale seq, or had nothing to do). The
    # caller uses these to choose the poll interval or the backoff.
    @next_expected[writer] ||= events.first['tab_seq']
    progressed = false
    events.each do |event|
      seq = event['tab_seq']
      if seq < @next_expected[writer]
        @externals.db.delete(event['id'])
        next
      end
      if seq > @next_expected[writer]
        unless skippable?(event)
          if progressed
            return :progressed
          else
            return :failed
          end
        end
        @next_expected[writer] = seq
      end
      response = forward(event)
      unless response && drained?(response)
        if progressed
          return :progressed
        else
          return :failed
        end
      end
      @externals.db.delete(event['id'])
      @next_expected[writer] = seq + 1
      progressed = true
    end
    if progressed
      return :progressed
    else
      return :idle
    end
  end

  def skippable?(event)
    # A held gap may be released once its earliest held row has waited longer
    # than the skip-timeout for the missing seq (measured from when it was
    # enqueued).
    @externals.time.now - event['enqueued_at'] >= SKIP_TIMEOUT_MS
  end

  def forward(event)
    # Forward one buffered write to saver and return saver's response, or nil if
    # the forward raises (saver unreachable) so the caller treats it as a failure
    # rather than letting the exception kill the drain thread.
    @externals.saver.forward(event['path'], event['body'])
  rescue StandardError
    nil
  end

  def drained?(response)
    # saver acked the write (a 2xx status), so its buffered row can be removed.
    (200..299).cover?(response.code.to_i)
  end

end

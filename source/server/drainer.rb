require 'zlib'
require_relative 'external/saver'
require_relative 'lib/log_stream'

class Drainer

  # A gap (a missing tab_seq below a higher buffered seq) is held this long,
  # measured from the held row's enqueued_at, before the drainer gives up and
  # releases past it. Only ever a superseded ITE is skipped (a test event is
  # sync-acked, so it can never be the missing seq).
  SKIP_TIMEOUT_MS = 5000

  # The drain loop sleeps this long between passes.
  POLL_INTERVAL_MS = 250

  def self.shard_of(kata_id, shard_count)
    # The drainer-worker index (0...shard_count) that owns this kata. A stable
    # hash (not String#hash, which is per-process random) so a kata maps to the
    # same shard across workers; a re-seed after a restart is safe regardless.
    Zlib.crc32(kata_id) % shard_count
  end

  def initialize(externals, shard_index: 0, shard_count: 1)
    # externals is the service locator (db, time). This worker drains the katas
    # whose shard_of is shard_index; the default single shard drains all.
    # next_expected is the per-writer reorder pointer (see drain).
    #
    # Each worker owns its own saver client (its own connection) rather than
    # sharing one: the workers forward concurrently and a single Net::HTTP
    # instance is not safe for concurrent requests, so a shared connection would
    # cross one worker's request with another's response.
    @externals = externals
    @shard_index = shard_index
    @shard_count = shard_count
    @next_expected = {}
    @saver = External::Saver.new(externals)
  end

  def drain
    # Forward buffered writes to saver, grouped by writer (kata_id, laptop_id) and
    # released in tab_seq order per writer, deleting each as it is sent
    # (delete-on-send). Fire-and-forget: saver's response is not read, so no
    # forward is retried and a forward lost while saver is unavailable is lost.
    # Writers are independent: a gap in one holds only that writer; every other
    # writer still drains.
    #
    # A row with no tab_seq (a client that sends none) has no position, so it
    # takes no part in any writer's ordering: it is released as it stands and
    # never seeds or advances a writer's reorder pointer.
    unsequenced, sequenced = mine.partition { |event| event['tab_seq'].nil? }
    unsequenced.each { |event| release(event) }
    by_writer(sequenced).each { |writer, events| release_in_order(writer, events) }
  end

  def run(sleeper: ->(ms) { sleep(ms / 1000.0) })
    # Loop: drain, then sleep the poll interval, until stop is called. The sleeper
    # is injectable so tests drive the loop without real sleeping; it is passed
    # milliseconds.
    @running = true
    while @running
      drain_pass
      sleeper.call(POLL_INTERVAL_MS)
    end
  end

  def stop
    # Ask the run loop to exit after its current pass.
    @running = false
  end

  private

  def drain_pass
    # One pass of the drain loop. A raise is logged and swallowed rather than
    # ending the loop: a row this shard cannot drain would otherwise stop it
    # draining every other kata it owns, and the row survives to raise again on
    # the next boot.
    drain
  rescue StandardError => error
    log("drain pass failed: #{error.class}: #{error.message}")
  end

  def log(message)
    # Report on the service's log stream, flushed so the line is not lost in the
    # buffer.
    stream = LogStream.current
    stream.puts(message)
    stream.flush
  end

  def mine?(kata_id)
    # Whether this worker's shard owns the kata.
    self.class.shard_of(kata_id, @shard_count) == @shard_index
  end

  def mine
    # The buffered rows of the katas this worker's shard owns.
    @externals.db.buffered_events.select { |event| mine?(event['kata_id']) }
  end

  def by_writer(events)
    # events grouped by writer, { [kata_id, laptop_id] => its rows, tab_seq
    # ascending }. Every writer grouped has at least one row.
    events.group_by { |event| [event['kata_id'], event['laptop_id']] }
          .transform_values { |rows| rows.sort_by { |event| event['tab_seq'] } }
  end

  def release_in_order(writer, events)
    # events are this writer's buffered rows, tab_seq ascending. Forward them in
    # tab_seq order from next_expected, seeded at first sight from the lowest
    # buffered seq (delete-on-send removes forwarded rows, so the buffer alone
    # cannot distinguish an already-forwarded prefix from a bottom gap). A row
    # above next_expected is a gap: hold it (and the rest) for a later pass,
    # unless it has aged past the skip-timeout, in which case skip the missing
    # seq and release from here. A row below next_expected is already past - a
    # skipped seq arriving late, or a redelivery of a forwarded one - so drop it
    # (delete unsent). Each released row is forwarded fire-and-forget and deleted
    # whether or not saver accepted it.
    @next_expected[writer] ||= events.first['tab_seq']
    events.each do |event|
      break if held?(writer, event)
      pass(writer, event)
    end
  end

  def held?(writer, event)
    # Whether event is above the writer's next_expected (a gap) and still
    # younger than the skip-timeout: it, and every row after it, waits for a
    # later pass.
    event['tab_seq'] > @next_expected[writer] && !skippable?(event)
  end

  def pass(writer, event)
    # Move the writer's reorder pointer past event. A row below next_expected is
    # already past, so it is dropped (deleted unsent). Any other row is next in
    # order, or past a gap aged beyond the skip-timeout: it is released, and the
    # seq after it is expected next.
    seq = event['tab_seq']
    if seq < @next_expected[writer]
      @externals.db.delete(event['id'])
    else
      release(event)
      @next_expected[writer] = seq + 1
    end
  end

  def release(event)
    # Send one buffered row to saver and drop it from the buffer, whether or not
    # saver accepted it (delete-on-send, fire-and-forget).
    forward(event)
    @externals.db.delete(event['id'])
  end

  def skippable?(event)
    # A held gap may be released once its earliest held row has waited longer
    # than the skip-timeout for the missing seq (measured from when it was
    # enqueued).
    @externals.time.now - event['enqueued_at'] >= SKIP_TIMEOUT_MS
  end

  def forward(event)
    # Forward one buffered write to saver, fire-and-forget: the response is not
    # read (delivery is best-effort). Rescue so a raised forward (saver
    # unreachable) does not kill the drain thread; the row is deleted either way.
    @saver.forward(event['path'], event['body'])
  rescue StandardError
    nil
  end

end

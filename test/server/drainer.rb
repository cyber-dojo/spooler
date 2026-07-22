require_relative 'test_base'
require_relative 'doubles/saver_http_distinct_connections_stub'

class DrainerTest < TestBase

  # TODO: For these tests I think it would be better if the database data started from
  # a standardized sequence of N good events. Then for tests where the events are
  # anomalous in some way, there would be explicit statements writing the anamoly
  # into this data, just before it is seeded into the db.

  test 'Dn0001', %w(
  | drain forwards every buffered write to saver, oldest first, and deletes each
  | as it is sent (delete-on-send)
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2, enqueued_at: 2000)
    stub = saver_returns(200, '{}')
    externals.drainer.drain
    assert_equal %w(/kata_ran_tests /kata_file_edit), stub.forwarded.map(&:path)
    assert_empty db.buffered_events
  end

  test 'Dn0004', %w(
  | a forward that raises (saver unreachable) does not raise out of drain, and the
  | row is deleted anyway: delivery is fire-and-forget, so an unreachable saver
  | loses the write rather than wedging the drain thread
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    saver_raises(Errno::ECONNREFUSED)
    externals.drainer.drain
    assert_empty db.buffered_events
  end

  test 'Dn0005', %w(
  | drain forwards a (kata, laptop)'s writes in tab_seq order, not arrival order:
  | tab_seq 2 arrives (is enqueued) first, tab_seq 1 arrives later, yet 1 is
  | forwarded first
  ) do
    db = in_memory_db
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2, enqueued_at: 8001)
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 8002)
    stub = saver_returns(200, '{}')
    externals.drainer.drain
    assert_equal %w(/kata_ran_tests /kata_file_edit), stub.forwarded.map(&:path)
    assert_empty db.buffered_events
  end

  test 'Dn0006', %w(
  | drain forwards up to a gap and holds the rest while the gap is younger than
  | the skip-timeout: with tab_seq 1 and 3 buffered (2 missing) it forwards 1 and
  | holds 3
  ) do
    db = in_memory_db
    held_at = 3000
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 3, enqueued_at: held_at)
    time_is(held_at + Drainer::SKIP_TIMEOUT_MS - 1) # gap still younger than the timeout
    stub = saver_returns(200, '{}')
    externals.drainer.drain
    assert_equal %w(/kata_ran_tests), stub.forwarded.map(&:path)
    assert_equal [3], db.buffered_events.map { |event| event['tab_seq'] }
  end

  test 'Dn0007', %w(
  | once a gap has gone unfilled for the skip-timeout drain skips it: with
  | tab_seq 1 and 3 (2 missing) and row 3 aged to the timeout, it forwards 1 then 3
  ) do
    db = in_memory_db
    held_at = 3000
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 3, enqueued_at: held_at)
    time_is(held_at + Drainer::SKIP_TIMEOUT_MS) # gap has reached the timeout
    stub = saver_returns(200, '{}')
    externals.drainer.drain
    assert_equal %w(/kata_ran_tests /kata_file_edit), stub.forwarded.map(&:path)
    assert_empty db.buffered_events
  end

  test 'Dn0008', %w(
  | a seq that arrives after its gap was already skipped is below next_expected,
  | so drain drops it (deletes it unsent) rather than forwarding it out of order
  ) do
    db = in_memory_db
    stub = saver_returns(200, '{}')
    held_at = 3000
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 3, enqueued_at: held_at)

    skip_at = held_at + Drainer::SKIP_TIMEOUT_MS
    time_is(skip_at)
    externals.drainer.drain # skips the missing 2, forwards 1 and 3

    db.append(path: 'kata_file_delete', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2, enqueued_at: skip_at + 50)
    time_is(skip_at + 100)
    externals.drainer.drain # the late tab_seq 2 is below next_expected

    assert_empty db.buffered_events
    refute_includes stub.forwarded.map(&:path), '/kata_file_delete'
  end

  test 'Dn0010', %w(
  | run drains then sleeps the poll interval between passes, until stop ends the
  | loop
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    saver_returns(200, '{}')
    drainer = externals.drainer
    sleeps = []
    sleeper = lambda do |ms|
      sleeps << ms
      drainer.stop if sleeps.size == 3
    end
    drainer.run(sleeper: sleeper)
    poll = Drainer::POLL_INTERVAL_MS
    assert_equal [poll, poll, poll], sleeps
  end

  test 'Dn0011', %w(
  | a sharded drainer drains only the katas in its shard; two shards of two
  | together drain every kata (a disjoint partition by kata_id)
  ) do
    db = in_memory_db
    saver_returns(200, '{}')
    katas = %w(aB3dE7 Xy9k2P Qw4rT6 Zx8cV2 Mn5bH1 Kp7jL9)
    katas.each_with_index do |kata, i|
      db.append(path: 'kata_ran_tests', body: %({"id":"#{kata}"}),
                kata_id: kata, laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000 + i)
    end
    Drainer.new(externals, shard_index: 0, shard_count: 2).drain
    remaining = db.buffered_events.map { |event| event['kata_id'] }.sort
    assert_equal katas.reject { |kata| Drainer.shard_of(kata, 2).zero? }.sort, remaining
    Drainer.new(externals, shard_index: 1, shard_count: 2).drain
    assert_empty db.buffered_events
  end

  test 'Dn0012', %w(
  | each drainer shard forwards through its own saver connection, never one
  | shared across shards: a single Net::HTTP instance is not safe for the
  | concurrent forwards of several shard threads, so every worker owns its own
  ) do
    db = in_memory_db
    http = saver_returns_per_connection
    kata0 = kata_for_shard(shard_count: 2, shard_index: 0)
    kata1 = kata_for_shard(shard_count: 2, shard_index: 1)
    db.append(path: 'kata_ran_tests', body: %({"id":"#{kata0}"}),
              kata_id: kata0, laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_ran_tests', body: %({"id":"#{kata1}"}),
              kata_id: kata1, laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    Drainer.new(externals, shard_index: 0, shard_count: 2).drain
    Drainer.new(externals, shard_index: 1, shard_count: 2).drain
    assert_equal 2, http.connections.size,
      'the two shards shared one saver connection instead of owning their own'
    assert_equal [1, 1], http.connections.map { |connection| connection.requests.size }
  end

  private

  # Inject the distinct-connection http transport so a test can see how many
  # saver connections the drainers create.
  def saver_returns_per_connection(code: 200, body: '{}')
    stub = SaverHttpDistinctConnectionsStub.new(SaverResponseStub.new(code: code, body: body))
    externals.instance_exec { @http = stub }
    stub
  end

  # A kata id that Drainer.shard_of maps to shard_index (of shard_count), so a
  # test can seed exactly one write per shard.
  def kata_for_shard(shard_count:, shard_index:)
    %w(aB3dE7 Xy9k2P Qw4rT6 Zx8cV2 Mn5bH1 Kp7jL9).find do |kata|
      Drainer.shard_of(kata, shard_count) == shard_index
    end
  end

  # An http transport (the Externals#http seam) whose every forwarded request
  # raises, standing in for saver being unreachable. Lets a test prove a raised
  # forward is swallowed by the drainer and the row is deleted anyway
  # (fire-and-forget delivery is best-effort, not retried).
  def saver_raises(error)
    stub = Class.new do
      def initialize(error)
        @error = error
      end
      def new(_hostname, _port)
        self
      end
      def request(_request)
        raise @error
      end
    end.new(error)
    externals.instance_exec { @http = stub }
    stub
  end

end

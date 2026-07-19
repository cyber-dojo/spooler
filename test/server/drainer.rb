require_relative 'test_base'

class DrainerTest < TestBase

  test 'Dn0001', %w(
  | drain forwards every buffered write to saver, oldest first, deletes each one
  | saver acks (2xx), and returns true (the pass hit no failure)
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2, enqueued_at: 2000)
    stub = saver_returns(200, '{}')
    assert externals.drainer.drain
    assert_equal %w(/kata_ran_tests /kata_file_edit), stub.forwarded.map(&:path)
    assert_empty db.buffered_events
  end

  test 'Dn0002', %w(
  | drain leaves a write buffered when saver does not ack it (500), and returns
  | false so the loop knows saver is failing
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    saver_returns(500, '{"exception":"saver down"}')
    refute externals.drainer.drain
    assert_equal 1, db.buffered_events.size
  end

  test 'Dn0003', %w(
  | drain stops the pass on the first failure: a 500 on the first row means the
  | second is not even attempted, and both stay buffered
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2, enqueued_at: 2000)
    stub = saver_returns(500, '{"exception":"saver down"}')
    refute externals.drainer.drain
    assert_equal 1, stub.forwarded.size
    assert_equal 2, db.buffered_events.size
  end

  test 'Dn0004', %w(
  | drain treats a forward that raises (saver unreachable) as a failure: it does
  | not raise, leaves the row buffered, and returns false
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    saver_raises(Errno::ECONNREFUSED)
    refute externals.drainer.drain
    assert_equal 1, db.buffered_events.size
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
    assert externals.drainer.drain
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
    assert externals.drainer.drain
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
    assert externals.drainer.drain
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

  test 'Dn0009', %w(
  | run drains repeatedly, sleeping a backoff that doubles from the poll interval
  | while saver keeps failing; stop ends the loop
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1, enqueued_at: 1000)
    saver_returns(500, '{"exception":"saver down"}')
    drainer = externals.drainer
    sleeps = []
    sleeper = lambda do |ms|
      sleeps << ms
      drainer.stop if sleeps.size == 4
    end
    drainer.run(sleeper: sleeper)
    poll = Drainer::POLL_INTERVAL_MS
    assert_equal [poll, poll * 2, poll * 4, poll * 8], sleeps
  end

  test 'Dn0010', %w(
  | run sleeps the poll interval on each healthy pass (no backoff when saver acks
  | or there is nothing to drain)
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

end

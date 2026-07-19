require_relative 'test_base'

class SpoolReplayTest < TestBase

  test 'Sr0001', %w(
  | replay re-forwards every buffered write to saver, oldest first, and drains
  | each on a 2xx, recovering writes persisted but not yet drained before a
  | restart
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1)
    db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2)
    stub = saver_returns(200, '{}')
    externals.spool.replay
    assert_equal %w(/kata_ran_tests /kata_file_edit), stub.forwarded.map(&:path)
    assert_empty db.buffered_events
  end

  test 'Sr0002', %w(
  | replay leaves a write buffered when saver fails (500), so it is retried on a
  | later restart rather than lost
  ) do
    db = in_memory_db
    db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1)
    saver_returns(500, '{"exception":"saver down"}')
    externals.spool.replay
    assert_equal 1, db.buffered_events.size
  end

end

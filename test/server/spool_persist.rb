require_relative 'test_base'
require_relative 'doubles/db_append_spy'

class SpoolPersistTest < TestBase

  test 'Sp0001', %w(
  | a write is durably appended to the buffer under its path, body and key, and
  | the route acks 200; intake does NOT forward to saver - the drainer does
  ) do
    spy = db_append_spy
    stub = saver_returns(200, ran_tests_result)
    time_is(1_700_000_000_000)
    response = post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 200, response.status
    assert_equal '{}', response.body
    assert_empty stub.forwarded
    assert_equal(
      [{ path: 'kata_ran_tests', body: ran_tests_body, kata_id: id58,
         laptop_id: laptop_id, tab_seq: 4, enqueued_at: 1_700_000_000_000 }],
      spy.appends
    )
  end

  test 'Sp0002', %w(
  | a write whose body is not JSON is rejected at intake with 400 and never
  | enters the buffer: an unparseable request can never become a valid saver
  | write, so buffering it would leave a poison row that never drains
  ) do
    spy = db_append_spy
    response, _stdout, _stderr = with_captured_stdout_stderr do
      post_json('/kata_ran_tests', 'this is not json')
    end
    assert_equal 400, response.status
    assert_empty spy.appends
  end

  test 'Sp0003', %w(
  | a redelivered write (same body) is deduped to one buffered row, because Spool
  | keys the append by the body's (id, laptop_id, tab_seq)
  ) do
    db = in_memory_db
    post_json('/kata_ran_tests', ran_tests_body)
    post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 1, db.buffered_events.size
  end

  test 'Sp0004', %w(
  | every write endpoint (kata_file_create .. kata_checked_out) appends and
  | acks 200
  ) do
    db = in_memory_db
    write_paths.each do |path|
      assert_equal 200, post_json("/#{path}", '{}').status
    end
    assert_equal write_paths.size, db.buffered_events.size
  end

  private

  def db_append_spy
    # Replace the buffer with a spy so the test can assert what the real Spool
    # did or did not persist, without touching real SQLite.
    spy = DbAppendSpy.new
    externals.instance_exec { @db = spy }
    spy
  end

  def write_paths
    %w(
      kata_file_create kata_file_delete kata_file_rename kata_file_edit
      kata_ran_tests kata_predicted_right kata_predicted_wrong
      kata_reverted kata_checked_out
    )
  end

end

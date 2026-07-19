require_relative 'test_base'
require_relative 'doubles/db_append_spy'

class SpoolPersistTest < TestBase

  test 'Sp0001', %w(
  | a write is persisted to the buffer under its kata id, carrying its path and
  | body, and saver's response is still relayed verbatim
  ) do
    spy = db_append_spy
    time_is(1_700_000_000_000)
    saver_returns(200, ran_tests_result)
    response = post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 200, response.status
    assert_equal ran_tests_result, response.body
    assert_equal(
      [{ path: 'kata_ran_tests', body: ran_tests_body,
         kata_id: id58, laptop_id: laptop_id, tab_seq: 4,
         enqueued_at: 1_700_000_000_000
      }],
      spy.appends
    )
  end

  test 'Sp0002', %w(
  | a write whose body is not JSON is rejected at intake with 400 and is not
  | forwarded to saver. It is refused rather than buffered because an
  | unparseable request can never become a valid saver write: buffered it would
  | be a poison row that never drains (saver would 400 it anyway), so it must
  | not enter the buffer in the first place
  ) do
    spy = db_append_spy
    stub = saver_returns(200, ran_tests_result)
    response, _stdout, _stderr = with_captured_stdout_stderr do
      post_json('/kata_ran_tests', 'this is not json')
    end
    assert_equal 400, response.status
    assert_empty spy.appends
    assert_empty stub.forwarded
  end

  test 'Sp0003', %w(
  | saver acking a write (2xx) drains it from the buffer (delete-on-ack), so it
  | is not left behind to be re-forwarded
  ) do
    db = in_memory_db
    saver_returns(200, ran_tests_result)
    post_json('/kata_ran_tests', ran_tests_body)
    assert_empty db.buffered_events
  end

  test 'Sp0004', %w(
  | when saver fails (500) the write stays in the buffer (undrained) so it can
  | be re-forwarded later, and the 500 is still relayed verbatim
  ) do
    db = in_memory_db
    saver_returns(500, '{"exception":"boom from saver"}')
    response = post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 500, response.status
    assert_equal '{"exception":"boom from saver"}', response.body
    assert_equal 1, db.buffered_events.size
  end

  test 'Sp0005', %w(
  | a redelivered write (saver still down, so both stay buffered) is deduped to
  | one row, because Spool passes its (kata_id, laptop_id, tab_seq) key from the
  | body through to the buffer
  ) do
    db = in_memory_db
    saver_returns(500, '{"exception":"saver down"}')
    post_json('/kata_ran_tests', ran_tests_body)
    post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 1, db.buffered_events.size
  end

  private

  def db_append_spy
    # Replace the buffer with a spy so the test can assert what the real Spool
    # did or did not persist, without touching real SQLite.
    spy = DbAppendSpy.new
    externals.instance_exec { @db = spy }
    spy
  end

end

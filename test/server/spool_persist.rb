require_relative 'test_base'
require_relative 'doubles/saver_http_stub'
require_relative 'doubles/db_append_spy'
require_source 'external/db'

class SpoolPersistTest < TestBase

  test 'Sp0001', %w(
  | a write is persisted to the buffer under its kata id, carrying its path and
  | body, and saver's response is still relayed verbatim
  ) do
    spy = db_append_spy
    saver_returns(200, ran_tests_result)
    response = post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 200, response.status
    assert_equal ran_tests_result, response.body
    assert_equal(
      [{ kata_id: id58, path: 'kata_ran_tests', body: ran_tests_body }],
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
  | saver acking a write (2xx) drains it from the buffer (delete-on-ack), so a
  | later boot replay will not re-forward it
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

  private

  def in_memory_db
    # Inject a real, isolated in-memory buffer so a test can observe what the
    # real Spool drained or left behind, without touching the shared file.
    db = External::Db.new(':memory:')
    externals.instance_exec { @db = db }
    db
  end

  def db_append_spy
    # Replace the buffer with a spy so the test can assert what the real Spool
    # did or did not persist, without touching real SQLite.
    spy = DbAppendSpy.new
    externals.instance_exec { @db = spy }
    spy
  end

  def with_captured_stdout_stderr
    # Redirect the app's error-log stream so a rejected write's logged
    # exception does not leak to the test runner's stdout.
    captured_stdout = StringIO.new(+'', 'w')
    old_stdout_stream = Thread.current[:stdout_stream]
    Thread.current[:stdout_stream] = captured_stdout
    response = yield
    [response, captured_stdout.string, '']
  ensure
    Thread.current[:stdout_stream] = old_stdout_stream
  end

  def saver_returns(code, body)
    # Inject a stub http transport so the write relays to a canned saver
    # response instead of a real saver.
    stub = SaverHttpStub.new(SaverResponseStub.new(code: code, body: body))
    externals.instance_exec { @http = stub }
    stub
  end

  def ran_tests_result
    # A canned saver 200 body.
    '{"kata_ran_tests":{"index":7}}'
  end

  def ran_tests_body
    # A realistic kata_ran_tests write body, keyed to this test's own kata id
    # (id58) so the recorded append is unambiguously this write's.
    {
      id: id58,
      files: { 'hiker.rb' => 'content' },
      stdout: { 'content' => 'out', 'truncated' => false },
      stderr: { 'content' => '',    'truncated' => false },
      status: '0',
      summary: 'red',
      laptop_id: laptop_id
    }.to_json
  end

end

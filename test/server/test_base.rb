require_relative 'id58_test_base'
require_relative 'capture_stdout_stderr'
require_relative 'doubles/saver_http_stub'
require_relative 'doubles/saver_http_raises'
require_relative 'doubles/time_stub'
require_relative 'helpers/externals'
require_relative 'helpers/rack'
require_relative 'require_source'
require 'json'
require 'stringio'
require_source 'external/db'

class TestBase < Id58TestBase

  include CaptureStdoutStderr
  include TestHelpersExternals
  include TestHelpersRack

  # An arbitrary well-formed laptop_id (SecureRandom.hex(32) format), used to
  # make event bodies in tests look like a real client's. Its value is not
  # significant.
  def laptop_id
    '9b1c7f0e4a2d6538c1e0fb94a7d213e6f5028b4c9de71a36085fc2b7d419e0a2'
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -
  # Shared injection helpers: each swaps a real collaborator into the app's
  # Externals by setting its memoized ivar (saver's house idiom).

  def in_memory_db
    # Inject a real, isolated in-memory buffer a test can seed and inspect
    # without touching the shared /sqlite file.
    db = External::Db.new(':memory:')
    externals.instance_exec { @db = db }
    db
  end

  def saver_returns(code, body)
    # Inject a stub http transport so a write reaches a canned saver response
    # instead of a real saver.
    stub = SaverHttpStub.new(SaverResponseStub.new(code: code, body: body))
    externals.instance_exec { @http = stub }
    stub
  end

  def saver_raises(error)
    # Inject an http transport that raises on every request, simulating saver
    # being unreachable (the forward raises rather than returning a response).
    stub = SaverHttpRaises.new(error)
    externals.instance_exec { @http = stub }
    stub
  end

  def time_is(now_ms)
    # Inject a fixed clock so a test controls the enqueued_at stamped on an append.
    stub = TimeStub.new(now_ms)
    externals.instance_exec { @time = stub }
    stub
  end

  def wait_until(timeout_s: 2)
    # Poll the block until it is truthy, failing rather than hanging if it never
    # becomes true within timeout_s. Used to wait for background drainer threads.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
    until yield
      flunk("condition not met within #{timeout_s}s") if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.005)
    end
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  def with_captured_stdout_stderr
    # Redirect the app's error-log stream so a rejected request's logged
    # exception does not leak to the test runner's stdout.
    captured_stdout = StringIO.new(+'', 'w')
    old_stdout_stream = Thread.current[:stdout_stream]
    Thread.current[:stdout_stream] = captured_stdout
    response = yield
    [response, captured_stdout.string, '']
  ensure
    Thread.current[:stdout_stream] = old_stdout_stream
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  def ran_tests_result
    # A canned saver 200 body for a kata_ran_tests relay.
    '{"kata_ran_tests":{"index":7}}'
  end

  def ran_tests_body
    # A realistic kata_ran_tests write body, keyed to this test's own kata id
    # (id58) so parallel tests never collide, and carrying the laptop_id and
    # tab_seq the browser stamps (the idempotency key).
    {
      id: id58,
      files: { 'hiker.rb' => 'content' },
      stdout: { 'content' => 'out', 'truncated' => false },
      stderr: { 'content' => '',    'truncated' => false },
      status: '0',
      summary: 'red',
      laptop_id: laptop_id,
      tab_seq: 4
    }.to_json
  end

end

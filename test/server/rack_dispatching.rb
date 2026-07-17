require_relative 'test_base'

class RackDispatchingTest < TestBase

  # - - - - - - - - - - - - - - - - - - - - - - - - - -
  # 200
  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  test 'Rd0001', %w(
  | dispatches to alive
  ) do
    assert_get('alive' , ''  , 'alive?', true)
    assert_get('alive?', '{}', 'alive?', true)
  end

  test 'Rd0002', %w(
  | dispatches to ready
  ) do
    assert_get('ready' , ''  , 'ready?', true)
    assert_get('ready?', '{}', 'ready?', true)
  end

  test 'Rd0003', %w(
  | dispatches to sha
  ) do
    def prober.sha
      '80206798f1c1e0b403f17ceb1e7510edea8d8e51'
    end
    assert_get('sha', '', 'sha', prober.sha)
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -
  # 404
  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  test 'Rd0004', %w(
  | dispatch has 404 when method name is not found
  ) do
    response, _stdout, _stderr = with_captured_stdout_stderr do
      post_json '/xyz', ''
    end
    assert_equal 404, response.status
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -
  # 400
  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  test 'Rd0005', %w(
  | dispatch has 400 status when non-empty body is not JSON
  ) do
    response, _stdout, _stderr = with_captured_stdout_stderr do
      get_json '/sha', 'abc'
    end
    assert_equal 400, response.status
  end

  test 'Rd0006', %w(
  | dispatch has 400 status when non-empty body is not a JSON Hash
  ) do
    response, _stdout, _stderr = with_captured_stdout_stderr do
      get_json '/sha', '[]'
    end
    assert_equal 400, response.status
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -
  # 500
  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  test 'Rd0007', %w(
  | dispatch has 500 status when implementation raises
  ) do
    def prober.sha
      raise ArgumentError, 'wibble'
    end
    assert_get_raises('sha', '', 500, 'wibble')
  end

  private

  def assert_get(name, body, expected_name, expected_body)
    response = get_json(name, body)
    assert_equal 200, response.status, response.body
    assert_equal 'application/json', response.headers['Content-Type']
    expected = { expected_name => expected_body }.to_json
    assert_equal expected, response.body, body
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  def assert_get_raises(name, body, expected_status, message)
    response, stdout, _stderr = with_captured_stdout_stderr do
      get_json "/#{name}", body
    end
    assert_exception_response(response, expected_status, message)
    assert_exception_stdout(stdout, name, message)
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  def assert_exception_response(response, expected_status, expected_message)
    expected_body = { 'exception' => expected_message }
    assert_equal 'application/json', response.headers['Content-Type'], :exception_body_type
    assert_equal expected_status, response.status, :exception_body_status
    assert_equal expected_body, JSON.parse!(response.body), :exception_body_content
  end

  def assert_exception_stdout(stdout, name, message)
    json = JSON.parse!(stdout)
    exception = json['exception']
    refute_nil exception
    assert_equal "/#{name}", exception['path']
    assert_equal message, exception['message']
    assert_equal 'Array', exception['backtrace'].class.name
    assert exception.key?('time')
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - -

  def with_captured_stdout_stderr
    captured_stdout = StringIO.new(+'', 'w')
    old_stdout_stream = Thread.current[:stdout_stream]
    Thread.current[:stdout_stream] = captured_stdout
    response = yield
    [response, captured_stdout.string, '']
  ensure
    Thread.current[:stdout_stream] = old_stdout_stream
  end

end

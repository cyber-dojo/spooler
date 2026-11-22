require_relative 'test_base'
require_source 'lib/log_stream'

class LogStreamTest < TestBase

  test 'Ls0001', %w(
  | the service logs to $stdout, where the container's logs are read from,
  | when no stream is set for the thread, as in production
  ) do
    old_stdout_stream = Thread.current[:stdout_stream]
    Thread.current[:stdout_stream] = nil
    assert_same $stdout, LogStream.current
  ensure
    Thread.current[:stdout_stream] = old_stdout_stream
  end

end

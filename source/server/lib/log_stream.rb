
module LogStream

  def self.current
    # The stream the service logs to: this thread's override, which a test sets
    # to capture what is logged, else $stdout, where the container's logs are
    # read from.
    Thread.current[:stdout_stream] || $stdout
  end

end

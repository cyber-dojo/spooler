require_relative 'saver_response_stub'

# Test double for the http transport (the Externals#http seam) that, like real
# Net::HTTP and unlike SaverHttpStub, returns a *distinct* connection for each
# .new(hostname, port) call and remembers every connection it created. Lets a
# test assert each drainer shard builds its own connection instead of all shards
# sharing one - a single Net::HTTP instance is not safe for the concurrent
# forwards of several shard threads.
class SaverHttpDistinctConnectionsStub

  def initialize(response)
    # Hold the canned saver response every handed-out connection replays.
    @response = response
    @connections = []
    @mutex = Mutex.new
  end

  def new(_hostname, _port)
    # Hand out a fresh connection each call and record it.
    connection = Connection.new(@response)
    @mutex.synchronize { @connections << connection }
    connection
  end

  def connections
    # Every connection handed out, in creation order (a snapshot).
    @mutex.synchronize { @connections.dup }
  end

  class Connection
    def initialize(response)
      # Hold the canned response and record each request forwarded through it.
      @response = response
      @requests = []
      @mutex = Mutex.new
    end

    def request(request)
      # Record the forwarded request and return the canned saver response.
      @mutex.synchronize { @requests << request }
      @response
    end

    def requests
      # The requests forwarded through this connection (a snapshot).
      @mutex.synchronize { @requests.dup }
    end
  end

end

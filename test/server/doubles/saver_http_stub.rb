# Test double for the http transport injected via Externals#http, standing in
# for Net::HTTP. Driving the pass-through through this seam exercises the real
# HttpJson::Requester and External::Saver code (not just the route).
#
# Like Net::HTTP, it answers .new(hostname, port); the returned connection
# records each forwarded request and returns a canned response. It is
# instance-based (no class-level state) so minitest's parallel executor cannot
# make two tests share a connection.
class SaverHttpStub

  def initialize(response)
    @connection = Connection.new(response)
  end

  def new(_hostname, _port)
    # HttpJson::Requester calls http.new(hostname, port) once at construction.
    @connection
  end

  def forwarded
    # The Net::HTTP request objects the pass-through sent, in order.
    @connection.requests
  end

  class Connection
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def request(request)
      # Record the forwarded request and return the canned saver response.
      @requests << request
      @response
    end
  end

end

# A canned saver response answering the three methods the pass-through relays:
# code (status), content_type, and body. code may be an Integer; the relay
# calls code.to_i.
class SaverResponseStub

  attr_reader :code, :body, :content_type

  def initialize(code:, body:, content_type: 'application/json')
    @code = code
    @body = body
    @content_type = content_type
  end

end

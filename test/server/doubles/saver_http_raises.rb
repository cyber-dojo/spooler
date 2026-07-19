# Test double for the http transport injected via Externals#http, standing in
# for Net::HTTP but raising on every request - simulating saver being
# unreachable (e.g. connection refused), which Net::HTTP surfaces as a raised
# exception rather than a response. Lets a test drive the drainer's handling of
# a forward that raises.
class SaverHttpRaises

  def initialize(error)
    # The exception each request raises.
    @error = error
  end

  def new(_hostname, _port)
    # HttpJson::Requester calls http.new(hostname, port) once at construction.
    self
  end

  def request(_request)
    # Raise instead of returning a response, as Net::HTTP does when the
    # connection cannot be made.
    raise @error
  end

end

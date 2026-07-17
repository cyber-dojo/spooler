class RequestError < RuntimeError

  def initialize(message)
    # A malformed client request; mapped to HTTP 400 by AppBase.
    super
  end

end

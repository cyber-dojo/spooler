class NoLongerImplementedError < RuntimeError

  def initialize(message)
    # A retired endpoint; mapped to HTTP 505 by AppBase.
    super
  end

end

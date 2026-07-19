class Backoff

  def initialize(base_ms:, cap_ms:)
    # base_ms is the delay used when healthy and the first delay after a failure;
    # cap_ms bounds how far the delay doubles.
    @base_ms = base_ms
    @cap_ms = cap_ms
    @current_ms = base_ms
  end

  def next_ms(ok:)
    # The ms to wait before the next attempt, given the last attempt's outcome.
    # A healthy pass resets to (and returns) the base; a failure returns the
    # current delay and doubles it for next time, never beyond the cap.
    return @current_ms = @base_ms if ok

    ms = @current_ms
    @current_ms = [@current_ms * 2, @cap_ms].min
    ms
  end

end

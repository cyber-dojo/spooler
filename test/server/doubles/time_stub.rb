# Test double for the clock injected via Externals#time. now returns a fixed
# epoch-millisecond value, so a test can control the t1 stamped on an append and
# (later) the "now" a skip-timeout compares against.
class TimeStub

  def initialize(now_ms)
    # The fixed epoch-ms value now returns.
    @now_ms = now_ms
  end

  def now
    @now_ms
  end

end

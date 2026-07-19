require_relative 'test_base'
require_source 'backoff'

class BackoffTest < TestBase

  test 'Bk0001', %w(
  | next_ms returns the base on a healthy pass and doubles from the base on
  | repeated failures; a healthy pass resets it back to the base
  ) do
    backoff = Backoff.new(base_ms: 100, cap_ms: 10_000)
    assert_equal 100, backoff.next_ms(ok: false) # first failure: the base
    assert_equal 200, backoff.next_ms(ok: false)
    assert_equal 400, backoff.next_ms(ok: false)
    assert_equal 100, backoff.next_ms(ok: true)  # healthy: base, and reset
    assert_equal 100, backoff.next_ms(ok: false) # doubling restarts from the base
    assert_equal 200, backoff.next_ms(ok: false)
  end

  test 'Bk0002', %w(
  | the backoff never exceeds the cap, however many failures
  ) do
    backoff = Backoff.new(base_ms: 100, cap_ms: 400)
    12.times { backoff.next_ms(ok: false) }
    assert_equal 400, backoff.next_ms(ok: false)
  end

end

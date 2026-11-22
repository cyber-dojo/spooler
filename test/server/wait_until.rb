require_relative 'test_base'

class WaitUntilTest < TestBase

  test 'Wu0001', %w(
  | wait_until fails, rather than hanging, when the condition it polls never
  | holds within its timeout
  ) do
    error = assert_raises(Minitest::Assertion) do
      wait_until(timeout_s: 0.01) { false }
    end
    assert_equal 'condition not met within 0.01s', error.message
  end

end

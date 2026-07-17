require_relative 'test_base'

class ProbingTest < TestBase

  test 'Pb0001', %w(
  | ready? is always true
  ) do
    assert prober.ready?
  end

  test 'Pb0002', %w(
  | alive? is always true
  ) do
    assert prober.alive?
  end

  test 'Pb0003', %w(
  | sha is the 40-char hex sha of the image's git commit
  ) do
    sha = prober.sha
    assert_equal 40, sha.size
    sha.each_char do |ch|
      assert '0123456789abcdef'.include?(ch)
    end
  end
end

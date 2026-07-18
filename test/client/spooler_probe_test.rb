require_relative 'test_base'
require_source 'prober'

class SpoolerProbeTest < TestBase

  test 'Cp0001', %w(
  | alive? is always true and answers without touching the spooler server
  ) do
    assert prober.alive?
  end

  test 'Cp0002', %w(
  | ready? proxies the spooler server's readiness probe over HTTP
  ) do
    assert prober.ready?
  end

  test 'Cp0003', %w(
  | sha is the 40-char hex sha of the spooler image's git commit,
  | fetched from the server over HTTP
  ) do
    sha = prober.sha
    assert_equal 40, sha.size
    sha.each_char do |ch|
      assert '0123456789abcdef'.include?(ch)
    end
  end

  private

  def prober
    # The client-side Prober, wired to the real spooler server over HTTP.
    Prober.new(externals)
  end

end

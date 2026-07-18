require_relative 'external/http'
require_relative 'external/spooler'

class Externals

  def spooler
    # The spooler service the client's probes query over HTTP.
    @spooler ||= External::Spooler.new(http)
  end

  def http
    # The low-level HTTP transport, injectable so tests can stub it.
    @http ||= External::Http.new
  end

end

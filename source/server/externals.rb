require 'net/http'
require_relative 'external/saver'
require_relative 'prober'

class Externals

  def http
    # The HTTP transport class injected into downstream clients. Defaulting
    # to Net::HTTP (a class answering .new(hostname, port).request(req)) lets
    # tests swap in a low-level stub.
    @http ||= Net::HTTP
  end

  def prober
    # The liveness/readiness/sha probe collaborator.
    @prober ||= Prober.new
  end

  def saver
    # The saver service this pass-through relays write events to (ADR B1).
    @saver ||= External::Saver.new(self)
  end

end

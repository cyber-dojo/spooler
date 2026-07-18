require_relative 'requester'
require_relative 'unpacker'

module HttpJsonHash

  def self.service(name, http, hostname, port)
    # Build a JSON-over-HTTP client: a Requester (transport) wrapped by an
    # Unpacker (parses the { method => result } response envelope).
    requester = Requester.new(http, hostname, port)
    Unpacker.new(name, requester)
  end

end

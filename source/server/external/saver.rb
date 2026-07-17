require_relative 'http_json/requester'

module External

  class Saver

    def initialize(externals)
      # Locate saver exactly as web's saver client does, and build a
      # requester over the injected http so tests can stub the transport.
      hostname = ENV.fetch('CYBER_DOJO_SAVER_HOSTNAME', 'saver')
      port = ENV['CYBER_DOJO_SAVER_PORT'].to_i
      @requester = HttpJson::Requester.new(externals.http, hostname, port)
    end

    def forward(path, body)
      # Relay one write call to saver's same path and return saver's raw
      # response for verbatim relay, including a non-2xx status (ADR B1).
      @requester.post(path, body)
    end

  end

end

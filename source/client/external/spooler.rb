require_relative '../http_json_hash/service'

module External

  class Spooler

    def initialize(http)
      # Locate the spooler server the way web's client does: the docker-compose
      # service is named 'server' and listens on CYBER_DOJO_SPOOLER_PORT.
      service = 'server'
      port = ENV['CYBER_DOJO_SPOOLER_PORT'].to_i
      @http = HttpJsonHash::service(self.class.name, http, service, port)
    end

    def ready?
      # GET the spooler's readiness probe.
      @http.get(__method__, {})
    end

    def sha
      # GET the git commit sha the spooler image was built from.
      @http.get(__method__, {})
    end

  end

end

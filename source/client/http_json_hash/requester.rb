require 'json'
require 'uri'

module HttpJsonHash

  class Requester

    def initialize(http, hostname, port)
      # Hold the injected transport and the target service's location.
      @http = http
      @hostname = hostname
      @port = port
    end

    def get(path, args)
      # Send a GET to /path with a JSON-encoded args body.
      request(path, args) do |uri|
        @http.get(uri)
      end
    end

    def post(path, args)
      # Send a POST to /path with a JSON-encoded args body.
      request(path, args) do |uri|
        @http.post(uri)
      end
    end

    private

    def request(path, args)
      # Build the request via the yielded verb, attach the JSON body, and run it.
      uri = URI.parse("http://#{@hostname}:#{@port}/#{path}")
      req = yield uri
      req.content_type = 'application/json'
      req.body = JSON.generate(args)
      @http.start(@hostname, @port, req)
    end

  end

end

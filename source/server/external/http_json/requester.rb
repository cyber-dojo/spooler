require 'net/http'
require 'uri'

module HttpJson

  class Requester

    def initialize(http, hostname, port)
      # http is injected (Net::HTTP by default) so tests can stub at the
      # lowest level: any class answering .new(hostname, port).request(req).
      @http = http
      @hostname = hostname
      @port = port
      @base_url = "http://#{hostname}:#{port}"
    end

    def post(path, body)
      # POST the raw body string to path and return the raw response,
      # unparsed, so a caller can relay saver's response verbatim. The body
      # is forwarded byte-for-byte (not re-serialized) to stay identical.
      #
      # Each post builds its own connection. Net::HTTP#request mutates the
      # object's socket and started flags, so a connection held across posts is
      # state that two threads forwarding at once would overwrite. Its own
      # connection costs nothing: the object is never started, so #request opens
      # a connection, sends with Connection: close, and closes it, leaving
      # nothing to reuse.
      uri = URI.parse("#{@base_url}/#{path}")
      request = Net::HTTP::Post.new(uri)
      request.content_type = 'application/json'
      request.body = body
      @http.new(@hostname, @port).request(request)
    end

  end

end

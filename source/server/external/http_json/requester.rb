require 'net/http'
require 'uri'

module HttpJson

  class Requester

    def initialize(http, hostname, port)
      # http is injected (Net::HTTP by default) so tests can stub at the
      # lowest level: any class answering .new(hostname, port).request(req).
      @http = http.new(hostname, port)
      @base_url = "http://#{hostname}:#{port}"
    end

    def post(path, body)
      # POST the given body string to path and return the raw response,
      # unparsed, so a caller can relay saver's response verbatim. The body
      # is posted as-is (not re-serialized here), so the caller controls the
      # exact bytes saver receives.
      uri = URI.parse("#{@base_url}/#{path}")
      request = Net::HTTP::Post.new(uri)
      request.content_type = 'application/json'
      request.body = body
      @http.request(request)
    end

  end

end

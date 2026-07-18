require 'net/http'

module External
  class Http

    def get(uri)
      # Build a GET request object for uri.
      KLASS::Get.new(uri)
    end

    def post(uri)
      # Build a POST request object for uri.
      KLASS::Post.new(uri)
    end

    def start(hostname, port, req)
      # Open a connection to hostname:port, run req, and return the response.
      KLASS.start(hostname, port) do |http|
        http.request(req)
      end
    end

    KLASS = Net::HTTP
  end
end

require_relative 'service_error'
require 'json'

module HttpJsonHash

  class Unpacker

    def initialize(name, requester)
      # Hold the collaborator name (for error context) and the transport.
      @name = name
      @requester = requester
    end

    # - - - - - - - - - - - - - - - - - - - - -

    def get(path, args)
      # GET /path and return the unwrapped result value.
      response = @requester.get(path, args)
      unpacked(response.body, path.to_s, args)
    end

    def post(path, args)
      # POST /path and return the unwrapped result value.
      response = @requester.post(path, args)
      unpacked(response.body, path.to_s, args)
    end

    private

    def unpacked(body, path, args)
      # Parse the { path => result } envelope, raising on a server exception.
      json = JSON.parse!(body)
      if json.has_key?('exception')
        service_error(path, args, body, json['exception'])
      end
      json[path]
    end

    # - - - - - - - - - - - - - - - - - - - - -

    def service_error(path, args, body, message)
      # Raise a ServiceError carrying the failing call's context.
      fail ::HttpJsonHash::ServiceError.new(path, args, @name, body, message)
    end

  end

end

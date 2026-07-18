module HttpJsonHash

  class ServiceError < RuntimeError

    def initialize(path, args, name, body, message)
      # Carry the failing call's path, args, service name, and raw body
      # alongside the exception message.
      @path = path
      @args = args
      @name = name
      @body = body
      super(message)
    end

    attr_reader :path, :args, :name, :body

  end

end

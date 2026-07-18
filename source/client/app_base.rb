require_relative 'silently'
require 'sinatra/base'
silently { require 'sinatra/contrib' } # N x "warning: method redefined"
require_relative 'http_json_hash/service_error'
require_relative 'lib/json_adapter'
require 'json'

class AppBase < Sinatra::Base

  silently { register Sinatra::Contrib }
  set :port, ENV['PORT']

  def initialize(externals)
    # Hold the injected service locator and boot Sinatra.
    @externals = externals
    super(nil)
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  def self.get_json(name, klass)
    # Register a GET route that dispatches to klass.new(externals).name.
    get "/#{name}", provides:[:json] do
      respond_to do |format|
        format.json {
          target = klass.new(@externals)
          result = target.public_send(name, **named_args)
          content_type :json
          "{\"#{name}\":#{result}}"
        }
      end
    end
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  def self.post_json(name, klass)
    # Register a POST route that dispatches to klass.new(externals).name.
    post "/#{name}", provides:[:json] do
      respond_to do |format|
        format.json {
          target = klass.new(@externals)
          result = target.public_send(name, **named_args)
          content_type :json
          "{\"#{name}\":#{result}}"
        }
      end
    end
  end

  private

  include JsonAdapter

  def named_args
    # Parse the request args (body JSON or query params) into a symbol-keyed Hash.
    if params.empty?
      args = json_hash_parse(request.body.read)
    else
      args = params
    end
    Hash[args.map{ |key,value| [key.to_sym, value] }]
  end

  def json_hash_parse(body)
    # Parse a JSON request body, defaulting an empty body to {}.
    if body === ''
      body = '{}'
    end
    json = json_parse(body)
    unless json.instance_of?(Hash)
      fail 'body is not JSON Hash'
    end
    json
  rescue JSON::ParserError
    fail 'body is not JSON'
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  set :show_exceptions, false

  error do
    # Map any uncaught error to a 500 with a JSON diagnostic body.
    error = $!
    status(500)
    content_type('application/json')
    info = {
      exception: {
        request: {
          time:Time.now,
          path:request.path,
          body:request.body.read,
          params:request.params
        },
        backtrace: error.backtrace
      }
    }
    exception = info[:exception]
    if error.instance_of?(::HttpJsonHash::ServiceError)
      exception[:http_service] = {
        path:error.path,
        args:error.args,
        name:error.name,
        body:error.body,
        message:error.message
      }
    else
      exception[:message] = error.message
    end
    diagnostic = json_pretty(info)
    puts diagnostic
    body diagnostic
  end

end

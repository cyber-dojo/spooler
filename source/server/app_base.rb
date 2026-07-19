require_relative 'silently'
require 'sinatra/base'
silently { require 'sinatra/contrib' } # N x "warning: method redefined"
require_relative 'lib/json_adapter'
require_relative 'lib/utf8_clean'
require_relative 'no_longer_implemented_error'
require_relative 'request_error'
require 'json'

class AppBase < Sinatra::Base

  silently { register Sinatra::Contrib } # respond_to
  set :json_encoder, Sinatra::JSON       # avoids MultiJson.encode deprecation warning
  set :port, ENV['PORT']
  set :host_authorization, { permitted_hosts: [] } # https://github.com/sinatra/sinatra/issues/2065#issuecomment-2484285707

  def initialize(externals)
    # Hold the injected service locator and boot Sinatra.
    @externals = externals
    super(nil)
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  def self.get_json(klass_name, method_name)
    # Register a GET route that dispatches to externals.klass_name.method_name.
    get "/#{method_name}", provides:[:json] do
      respond_to do |format|
        format.json do
          args = to_json_object(request_body)
          json_result(klass_name, method_name, args)
        end
      end
    end
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  def self.post_json(klass_name, method_name)
    # Register a POST route that dispatches to externals.klass_name.method_name.
    post "/#{method_name}", provides:[:json] do
      respond_to do |format|
        format.json do
          args = to_json_object(request_body)
          json_result(klass_name, method_name, args)
        end
      end
    end
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  def self.post_pass_through(path)
    # Register a POST route that persists the write to the durable buffer, then
    # forwards it to saver and returns saver's response verbatim: status
    # (including a non-2xx such as 500), content-type, and body. The request
    # body (including the tab_seq ordering field) is forwarded byte-for-byte;
    # saver owns the write contract.
    post "/#{path}" do
      relayed = @externals.spool.write(path.to_s, request_body)
      status(relayed.code.to_i)
      headers['Content-Type'] = relayed.content_type || 'application/json'
      body(relayed.body)
    end
  end

  private

  include JsonAdapter
  include Utf8

  def json_result(klass_name, method_name, args)
    # Call the named collaborator method with the request args and
    # wrap its return value as { method_name => result } JSON.
    named_args = Hash[args.map{ |key,value| [key.to_sym, value] }]
    target = @externals.public_send(klass_name)
    result = target.public_send(method_name, **named_args)
    content_type(:json)
    { method_name.to_s => result }.to_json
  end

  def to_json_object(body)
    # Parse the request body (or query params) into a Hash of args.
    if body != ''
      json = json_parse(body)
    elsif params.empty?
      json = {}
    else
      json = params.map{ |key,value| [key,value] }.to_h
    end
    unless json.instance_of?(Hash)
      fail RequestError, 'body is not JSON Hash'
    end
    json
  rescue JSON::ParserError
    fail RequestError, 'body is not JSON'
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  set :show_exceptions, false

  error do
    # Map any uncaught error to a status code, log it, and return the message.
    error = $!
    if error.is_a?(NoLongerImplementedError)
      status(505)
    elsif error.is_a?(RequestError)
      status(400)
    else
      status(500)
    end
    message = Utf8.clean(error.message)
    stdout_stream.puts(json_pretty({
      exception: {
        path: Utf8.clean(request.path),
        body: Utf8.clean(request_body),
        backtrace: error.backtrace,
        message: message,
        time: Time.now
      }
    }))
    stdout_stream.flush
    content_type('application/json')
    body(json_pretty({ exception: message }))
  end

  # - - - - - - - - - - - - - - - - - - - - - -

  def stdout_stream
    # The stream errors are logged to (per-thread override, else $stdout).
    Thread.current[:stdout_stream] || $stdout
  end

  def request_body
    # Read the full request body from the start.
    request.body.rewind
    request.body.read
  end

end

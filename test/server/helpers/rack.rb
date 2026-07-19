require 'rack/test'
require_relative '../require_source'
require_source 'app'

module TestHelpersRack

  include Rack::Test::Methods

  def app
    @app ||= App.new(externals)
  end

  def get_json(path, args)
    get(path, {}, json_request(args))
    last_response
  end

  def post_json(path, data)
    post(path, data, JSON_REQUEST_HEADERS)
    last_response
  end

  def json_request(args)
    {
      input: args,
      CONTENT_TYPE: 'application/json', # sent
      HTTP_ACCEPT: 'application/json'   # want
    }
  end

  JSON_REQUEST_HEADERS = {
    'CONTENT_TYPE' => 'application/json', # sent
    'HTTP_ACCEPT' => 'application/json'   # want
  }

end

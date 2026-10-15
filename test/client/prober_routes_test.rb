require 'rack/test'
require_relative 'test_base'
require_source 'app'

class ProberRoutesTest < TestBase

  include Rack::Test::Methods

  test 'Cr7xA1', %w(
  | GET /alive? returns true as JSON
  ) do
    assert_equal({ 'alive?' => true }, get_json('/alive?'))
  end

  test 'Cr7xA2', %w(
  | GET /ready? returns true as JSON
  ) do
    assert_equal({ 'ready?' => true }, get_json('/ready?'))
  end

  test 'Cr7xA3', %w(
  | GET /sha returns the sha of the spooler image's git commit as JSON
  ) do
    assert_equal({ 'sha' => externals.spooler.sha }, get_json('/sha'))
  end

  private

  def app
    # The client's own Sinatra app, driven in-process by rack-test.
    App.new(externals)
  end

  def get_json(path)
    # GET path asking for JSON, assert a 200 JSON response, return its parsed body.
    get(path, {}, { 'HTTP_ACCEPT' => 'application/json' })
    assert_equal 200, last_response.status
    assert_equal 'application/json', last_response.headers['Content-Type']
    JSON.parse(last_response.body)
  end

end

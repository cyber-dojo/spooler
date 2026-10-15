require_relative 'test_base'
require_source 'http_json_hash/service'
require 'json'

class ServiceErrorTest < TestBase

  test 'Cs4eA1', %w(
  | A call the server rejects with an exception reply raises ServiceError.
  | The error carries the call's path, args, service name, raw body and message.
  ) do
    error = assert_raises(HttpJsonHash::ServiceError) do
      spooler_service.get(:ready?, { x: 1 })
    end
    assert_equal 'ready?', error.path
    assert_equal({ x: 1 }, error.args)
    assert_equal 'Spooler', error.name
    message = 'wrong number of arguments (given 1, expected 0)'
    assert_equal({ 'exception' => message }, JSON.parse(error.body))
    assert_equal message, error.message
  end

  private

  def spooler_service
    # The JSON-over-HTTP client for the spooler server, built as External::Spooler builds it.
    port = ENV['CYBER_DOJO_SPOOLER_PORT'].to_i
    HttpJsonHash::service('Spooler', externals.http, 'server', port)
  end

end

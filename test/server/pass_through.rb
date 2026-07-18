require_relative 'test_base'
require_relative 'doubles/saver_http_stub'

class PassThroughTest < TestBase

  test 'Pt0001', %w(
  | saver's 200 response is relayed verbatim: status, content-type and body
  ) do
    saver_returns(200, ran_tests_result)
    response = post_json('/kata_ran_tests', ran_tests_body)
    assert_equal 200, response.status
    assert_equal 'application/json', response.headers['Content-Type']
    assert_equal ran_tests_result, response.body
  end

  test 'Pt0002', %w(
  | the request path and body are forwarded to saver byte-for-byte
  ) do
    stub = saver_returns(200, ran_tests_result)
    body = ran_tests_body
    post_json('/kata_ran_tests', body)
    assert_equal 1, stub.forwarded.size
    request = stub.forwarded[0]
    assert_equal '/kata_ran_tests', request.path
    assert_equal body, request.body
  end

  test 'Pt0003', %w(
  | a non-2xx saver response (eg 500) is relayed verbatim: status and body
  ) do
    saver_returns(500, '{"exception":"boom from saver"}')
    response = post_json('/kata_file_edit', '{"files":{}}')
    assert_equal 500, response.status
    assert_equal '{"exception":"boom from saver"}', response.body
  end

  test 'Pt0004', %w(
  | every write endpoint kata_file_create..kata_checked_out is exposed
  | and forwards to its own same-named path
  ) do
    stub = saver_returns(200, '{}')
    write_paths.each { |path| post_json("/#{path}", '{}') }
    forwarded = stub.forwarded.map { |request| request.path }
    assert_equal write_paths.map { |path| "/#{path}" }, forwarded
  end

  test 'Pt0005', %w(
  | the tab_seq ordering field is relayed to saver in the write body, not
  | consumed by the spooler: saver owns the write contract
  ) do
    stub = saver_returns(200, ran_tests_result)
    sent = {
      id: 'AbCd3E',
      files: { 'hiker.rb' => 'content' },
      stdout: { 'content' => 'out', 'truncated' => false },
      stderr: { 'content' => '',    'truncated' => false },
      status: '0',
      summary: 'red',
      laptop_id: laptop_id,
      tab_seq: 42
    }
    post_json('/kata_ran_tests', sent.to_json)
    forwarded = JSON.parse(stub.forwarded[0].body)
    assert_equal 42, forwarded['tab_seq']
    assert_equal JSON.parse(sent.to_json), forwarded
  end

  private

  def saver_returns(code, body)
    stub = SaverHttpStub.new(SaverResponseStub.new(code: code, body: body))
    externals.define_singleton_method(:http) { stub }
    stub
  end

  def write_paths
    %w(
      kata_file_create kata_file_delete kata_file_rename kata_file_edit
      kata_ran_tests kata_predicted_right kata_predicted_wrong
      kata_reverted kata_checked_out
    )
  end

  def ran_tests_result
    '{"kata_ran_tests":{"index":7}}'
  end

  def ran_tests_body
    {
      id: 'AbCd3E',
      files: { 'hiker.rb' => 'content' },
      stdout: { 'content' => 'out', 'truncated' => false },
      stderr: { 'content' => '',    'truncated' => false },
      status: '0',
      summary: 'red',
      laptop_id: laptop_id
    }.to_json
  end

end

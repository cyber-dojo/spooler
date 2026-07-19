require 'json'
require_relative 'request_error'

class Spool

  def initialize(externals)
    # Hold the service locator so writes can reach the durable buffer (db) and
    # the clock. The drainer, not the Spool, forwards to saver.
    @externals = externals
  end

  def write(path, body)
    # Durably append the write to the buffer, stamping its enqueue time; the
    # drainer forwards it to saver asynchronously, so this does not touch saver.
    # A body that is not JSON raises (mapped to 400) before anything is buffered.
    fields = json_body(body)
    @externals.db.append(
      path:        path,
      body:        body,
      kata_id:     fields['id'],
      laptop_id:   fields['laptop_id'],
      tab_seq:     fields['tab_seq'],
      enqueued_at: @externals.time.now
    )
    nil
  end

  private

  def json_body(body)
    # The write body parsed once, so the buffer can be keyed by its
    # (id, laptop_id, tab_seq) idempotency fields (id is the kata id; each kata
    # is its own ordered log). A body that is not JSON is rejected here with a
    # 400 rather than buffered: an unparseable request can never become a valid
    # saver write, so buffering it would leave a poison row that never drains
    # (saver would 400 it anyway).
    JSON.parse(body)
  rescue JSON::ParserError
    raise RequestError, 'body is not JSON'
  end

end

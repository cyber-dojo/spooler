require 'json'
require_relative 'request_error'

class Spool

  def initialize(externals)
    # Hold the service locator so writes can reach the durable buffer (db)
    # and the saver forwarder.
    @externals = externals
  end

  def write(path, body)
    # Persist the write to the durable buffer before forwarding it, forward it
    # to saver, and delete it from the buffer once saver acks (delete-on-ack) so
    # only undrained writes remain. Return saver's raw response for verbatim
    # relay; a non-2xx leaves the row buffered for a later re-forward.
    fields = json_body(body)
    id = @externals.db.append(
      path:        path,
      body:        body,
      kata_id:     fields['id'],
      laptop_id:   fields['laptop_id'],
      tab_seq:     fields['tab_seq'],
      enqueued_at: @externals.time.now
    )
    response = @externals.saver.forward(path, body)
    @externals.db.delete(id) if drained?(response)
    response
  end

  private

  def drained?(response)
    # saver acked the write (a 2xx status), so its buffered row can be removed.
    (200..299).cover?(response.code.to_i)
  end

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

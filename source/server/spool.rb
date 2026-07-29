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
      tab_seq:     tab_seq_of(fields),
      enqueued_at: @externals.time.now
    )
    nil
  end

  private

  def tab_seq_of(fields)
    # The write's ordering position: the tab's own event counter, or nil when the
    # client sends none (an old or non-JS browser), which claims no position and
    # is released unordered by the drainer. A tab_seq that is present but not an
    # integer is rejected here with a 400 rather than buffered: the drainer
    # releases a writer's writes in numeric tab_seq order, so a value it cannot
    # compare could never drain, and the row would sit in the buffer forever.
    tab_seq = fields['tab_seq']
    return tab_seq if tab_seq.nil? || tab_seq.is_a?(Integer)

    raise RequestError, 'tab_seq is not an integer'
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

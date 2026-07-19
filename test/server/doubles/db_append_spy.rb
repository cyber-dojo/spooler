# Test double for the buffer collaborator injected via Externals#db. It stands
# in for External::Db and records the #append calls the real Spool makes, so a
# test can assert what was (or was not) persisted without touching real SQLite.
# Spool#write only calls #append; a double that canned reads or simulated an
# append failure would be a different specialization with its own name.
class DbAppendSpy

  attr_reader :appends

  def initialize
    # Each recorded append, in call order.
    @appends = []
  end

  def append(path:, body:, kata_id:, laptop_id:, tab_seq:, enqueued_at:)
    # Record one persisted write instead of storing it; return a stand-in row
    # id (the caller may pass it back to delete).
    @appends << {
      path: path, body: body,
      kata_id: kata_id, laptop_id: laptop_id, tab_seq: tab_seq,
      enqueued_at: enqueued_at
    }
    @appends.size
  end

  def delete(_id)
    # This double observes appends only; draining (delete-on-ack) is exercised
    # against a real in-memory Db, so a delete here is accepted and ignored.
  end

end

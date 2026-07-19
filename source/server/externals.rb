require 'net/http'
require_relative 'drainer'
require_relative 'external/db'
require_relative 'external/saver'
require_relative 'external/time'
require_relative 'prober'
require_relative 'spool'

class Externals

  def time
    # The clock that stamps each write's t1 enqueue timestamp (and, later, ages
    # the reorder buffer's gaps). Injectable so tests control time.
    @time ||= External::Time.new
  end

  def db
    # The durable on-disk buffer (SQLite) each write is persisted to before
    # being forwarded to saver. Its file lives on the mounted /sqlite volume.
    @db ||= External::Db.new('/sqlite/spooler.db')
  end

  def drainer
    # Forwards buffered writes to saver in the background, deleting each on ack.
    @drainer ||= Drainer.new(self)
  end

  def http
    # The HTTP transport class injected into downstream clients. Defaulting
    # to Net::HTTP (a class answering .new(hostname, port).request(req)) lets
    # tests swap in a low-level stub.
    @http ||= Net::HTTP
  end

  def prober
    # The liveness/readiness/sha probe collaborator.
    @prober ||= Prober.new
  end

  def saver
    # The saver service each buffered write is forwarded to.
    @saver ||= External::Saver.new(self)
  end

  def spool
    # The model that persists each write to the buffer and forwards it to saver.
    @spool ||= Spool.new(self)
  end

end

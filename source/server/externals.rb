require 'net/http'
require_relative 'external/db'
require_relative 'external/time'

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

  def http
    # The HTTP transport class injected into downstream clients. Defaulting
    # to Net::HTTP (a class answering .new(hostname, port).request(req)) lets
    # tests swap in a low-level stub.
    @http ||= Net::HTTP
  end

end

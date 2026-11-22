require 'net/http'
require_relative 'external/db'
require_relative 'external/time'

class Externals

  def initialize(db_path: '/sqlite/spooler.db')
    # db_path is the file the durable buffer lives in: by default on the mounted
    # /sqlite volume.
    @db_path = db_path
  end

  def time
    # The clock that stamps each write's t1 enqueue timestamp (and, later, ages
    # the reorder buffer's gaps). Injectable so tests control time.
    @time ||= External::Time.new
  end

  def db
    # The durable on-disk buffer (SQLite) each write is persisted to before
    # being forwarded to saver, in the file at db_path.
    @db ||= External::Db.new(@db_path)
  end

  def http
    # The HTTP transport class injected into downstream clients. Defaulting
    # to Net::HTTP (a class answering .new(hostname, port).request(req)) lets
    # tests swap in a low-level stub.
    @http ||= Net::HTTP
  end

end

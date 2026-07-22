require_relative 'drainer'
require_relative 'prober'
require_relative 'spool'

class Model

  def initialize(externals)
    # Hold the outward boundary (db, time, http) so the inward domain objects
    # built here can reach it. Externals is the outside world; Model is this
    # service's own logic over it: accept a write, buffer it, drain it to saver.
    @externals = externals
  end

  def spool
    # The write path: persists each write to the durable buffer (see Spool).
    @spool ||= Spool.new(@externals)
  end

  def drainer
    # A single unsharded drainer (shard_count 1) over the whole buffer, so it
    # drains every kata (see Drainer). Production runs a sharded DrainerPool
    # built directly from externals instead.
    @drainer ||= Drainer.new(@externals)
  end

  def prober
    # The liveness/readiness/sha probe collaborator.
    @prober ||= Prober.new
  end

end

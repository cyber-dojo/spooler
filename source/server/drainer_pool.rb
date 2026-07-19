require_relative 'drainer'

class DrainerPool

  def initialize(externals, shard_count:)
    # One Drainer worker per shard; each owns the katas whose shard_of is its
    # index (Drainer.shard_of), so a kata is drained by exactly one worker and
    # different katas drain in parallel while each stays ordered.
    @workers = (0...shard_count).map do |index|
      Drainer.new(externals, shard_index: index, shard_count: shard_count)
    end
  end

  def start(sleeper: ->(ms) { sleep(ms / 1000.0) })
    # Run each worker's drain loop in its own background thread.
    @threads = @workers.map { |worker| Thread.new { worker.run(sleeper: sleeper) } }
    self
  end

  def stop
    # Ask every worker to finish its current pass, then wait for the threads.
    # join re-raises a thread that died, so a worker crash surfaces here.
    @workers.each(&:stop)
    @threads.each(&:join)
  end

end

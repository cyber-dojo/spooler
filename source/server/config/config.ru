$stdout.sync = true
$stderr.sync = true

require 'rack'
use Rack::Deflater, if: ->(_, _, _, body) { body.any? && body[0].length > 512 }

if ENV['CYBER_DOJO_PROMETHEUS'] === 'true'
  require 'prometheus/middleware/collector'
  require 'prometheus/middleware/exporter'
  use Prometheus::Middleware::Collector
  use Prometheus::Middleware::Exporter
end

require_relative '../app'
require_relative '../externals'
require_relative '../drainer_pool'
externals = Externals.new

# Start the drainer: worker threads that forward buffered writes to saver in the
# background, draining any rows a previous process left undrained on start and
# then continuously. shard_count is the number of worker threads; a kata is
# owned by one worker, so different katas forward in parallel while each stays
# ordered. Sizing shard_count against peak load is an open question (see the ADR).
drainer_shard_count = (ENV['CYBER_DOJO_SPOOLER_DRAINER_SHARDS'] || '4').to_i
DrainerPool.new(externals, shard_count: drainer_shard_count).start

run App.new(externals)

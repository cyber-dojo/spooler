require_relative 'test_base'
require_source 'drainer_pool'

class DrainerPoolTest < TestBase

  test 'Dp0001', %w(
  | N sharded worker threads draining concurrently deliver every buffered write
  | to saver exactly once, each kata in tab_seq order, even when events arrived
  | out of order and interleaved across katas
  ) do
    db = in_memory_db
    stub = saver_returns(200, '{}')

    katas = (1..20).map { |n| format('k%05d', n) }
    per_kata = 5
    at = 1000
    # Append reverse-seq (5..1) and interleaved across katas: within a kata the
    # events arrive out of order, and no kata's events are contiguous in the
    # buffer. enqueued_at increases with every append (real arrival order).
    per_kata.downto(1) do |seq|
      katas.each do |kata|
        at += 1
        db.append(path: 'kata_ran_tests', body: %({"id":"#{kata}","tab_seq":#{seq}}),
                  kata_id: kata, laptop_id: laptop_id, tab_seq: seq, enqueued_at: at)
      end
    end

    pool = DrainerPool.new(externals, shard_count: 4)
    pool.start(sleeper: ->(_ms) { sleep(0.001) })
    wait_until { db.buffered_events.empty? }
    pool.stop

    forwarded = stub.forwarded.map { |request| JSON.parse(request.body) }
    assert_equal katas.size * per_kata, forwarded.size
    by_kata = forwarded.group_by { |event| event['id'] }
    assert_equal katas.sort, by_kata.keys.sort
    by_kata.each_value do |events|
      assert_equal (1..per_kata).to_a, events.map { |event| event['tab_seq'] }
    end
    assert_empty db.buffered_events
  end

end

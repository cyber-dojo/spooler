module External

  class Time

    def now
      # Wall-clock epoch milliseconds. Wall clock (not monotonic) because t1 is
      # durable and is compared by a drainer that may be a later process, and
      # only wall clock is comparable across processes and restarts.
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end

  end

end

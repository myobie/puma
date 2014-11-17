require 'thread'

module Puma
  # A simple thread pool management object.
  #
  class ThreadPool

    # Maintain a minimum of +min+ and maximum of +max+ threads
    # in the pool.
    #
    # The block passed is the work that will be performed in each
    # thread.
    #
    def initialize(min, max, *extra, &block)
      @cond = ConditionVariable.new
      @mutex = Mutex.new

      @todo = []

      @spawned = 0
      @waiting = 0

      @min = Integer(min)
      @max = Integer(max)
      @block = block
      @extra = extra

      @shutdown = false

      @trim_requested = 0

      @workers = []

      @auto_trim = nil
      @timer_outer = nil

      @mutex.synchronize do
        @min.times { spawn_thread }
      end
    end

    attr_reader :spawned, :trim_requested

    # How many objects have yet to be processed by the pool?
    #
    def backlog
      @mutex.synchronize { @todo.size }
    end

    # :nodoc:
    #
    # Must be called with @mutex held!
    #
    def spawn_thread
      @spawned += 1

      th = Thread.new do
        todo  = @todo
        block = @block
        mutex = @mutex
        cond  = @cond

        extra = @extra.map { |i| i.new }

        while true
          work = nil

          continue = true

          mutex.synchronize do
            while todo.empty?
              if @trim_requested > 0
                @trim_requested -= 1
                continue = false
                break
              end

              if @shutdown
                continue = false
                break
              end

              @waiting += 1
              cond.wait mutex
              @waiting -= 1
            end

            work, created_at = todo.shift if continue
          end

          break unless continue

          Thread.current.keys.each do |key|
            Thread.current[key] = nil unless key == :__recursive_key__
          end

          block.call(work, *extra)
        end

        mutex.synchronize do
          @spawned -= 1
          @workers.delete th
        end
      end

      @workers << th

      th
    end

    private :spawn_thread

    # Add +work+ to the todo list for a Thread to pickup and process.
    def <<(work)
      @mutex.synchronize do
        if @shutdown
          raise "Unable to add work while shutting down"
        end

        @todo << [work, Time.now.utc]

        if @waiting < @todo.size and @spawned < @max
          spawn_thread
        end

        @cond.signal
      end
    end

    # If too many threads are in the pool, tell one to finish go ahead
    # and exit. If +force+ is true, then a trim request is requested
    # even if all threads are being utilized.
    #
    def trim(force=false)
      @mutex.synchronize do
        if (force or @waiting > 0) and @spawned - @trim_requested > @min
          @trim_requested += 1
          @cond.signal
        end
      end
    end

    def timeout_all_older_than(timeout_seconds)
      @mutex.synchronize do
        now = Time.now.utc
        @todo.delete_if { |_, time| now - time > timeout_seconds }.
                   each { |work, _| work.timeout! if work.respond_to?(:timeout!) }
      end
    end

    class Worker
      def initialize(pool, timeout)
        @pool = pool
        @timeout = timeout
        @running = false
      end

      def start!
        @running = true
        @thread = create_worker_thread
      end

      def create_worker_thread
        raise NotImplementedError
      end

      def stop
        @running = false
        @thread.wakeup
      end
    end

    class AutoTrim < Worker
      def create_worker_thread
        Thread.new do
          while @running
            @pool.trim
            sleep @timeout
          end
        end
      end
    end

    class TimerOuter < Worker
      def create_worker_thread
        Thread.new do
          while @running
            @pool.timeout_all_older_than(@timeout)
            sleep 1
          end
        end
      end
    end

    def auto_trim!(timeout=5)
      @auto_trim = AutoTrim.new(self, timeout)
      @auto_trim.start!
    end

    def timeout!(timeout = 15)
      @timer_outer = TimerOuter.new(self, timeout)
      @timer_outer.start!
    end

    # Tell all threads in the pool to exit and wait for them to finish.
    #
    def shutdown
      @mutex.synchronize do
        @shutdown = true
        @cond.broadcast

        @auto_trim.stop if @auto_trim
        @timer_outer.stop if @timer_outer
      end

      # Use this instead of #each so that we don't stop in the middle
      # of each and see a mutated object mid #each
      @workers.first.join until @workers.empty?

      @spawned = 0
      @workers = []
    end
  end
end

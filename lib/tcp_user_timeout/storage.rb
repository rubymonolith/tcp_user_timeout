# frozen_string_literal: true

module TcpUserTimeout
  # Fiber-safe scoped storage for the in-flight timeout value.
  #
  # On Ruby 3.2+ uses `Fiber[]` (inheritable fiber storage) so that:
  #
  #   - Child fibers spawned inside a `with_timeout` block inherit the
  #     deadline. This matters for Async / Falcon and any code that uses
  #     fiber-per-task concurrency under a request or job.
  #   - Threads spawned inside a `with_timeout` block also inherit the
  #     deadline (each new thread starts with a main fiber that copies the
  #     spawning fiber's storage). This matters for jobs that spawn helper
  #     threads to do parallel I/O.
  #   - Threads or fibers spawned *outside* the block do not see the value.
  #
  # On older Rubies, falls back to `Thread.current[]` (which is actually
  # fiber-local in MRI). That path does not propagate to child fibers or
  # threads, but it is still correct for plain thread-per-request servers.
  module Storage
    FIBER_STORAGE = Fiber.respond_to?(:[])

    module_function

    def [](key)
      FIBER_STORAGE ? Fiber[key] : Thread.current[key]
    end

    def []=(key, value)
      if FIBER_STORAGE
        Fiber[key] = value
      else
        Thread.current[key] = value
      end
    end
  end
end

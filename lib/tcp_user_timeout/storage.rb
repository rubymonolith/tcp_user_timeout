# frozen_string_literal: true

module TcpUserTimeout
  # Fiber-safe scoped storage. Uses Ruby 3.2+ inheritable fiber storage
  # (Fiber[]) when available so child fibers (e.g. spawned by Async, Falcon)
  # inherit the deadline; falls back to Thread.current[] on older Rubies,
  # which is correct for thread-per-request servers but does not propagate
  # across fibers.
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

# frozen_string_literal: true

require_relative 'test_helper'

# Safety tests: prove that the core library behaves under threading,
# fibers, fork, and concurrent install. These are the failure modes that
# would silently corrupt timeout state in production.
#
# These tests are platform-agnostic — none of them exercise the kernel-
# level setsockopt behavior. They test thread/fiber/fork-local semantics
# and the idempotence of install!.
class TcpUserTimeoutSafetyTest < Minitest::Test
  def teardown
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
    TcpUserTimeout.global_default_seconds = nil
    TcpUserTimeout.exempt_hosts = []
  end

  # ---- Thread inheritance / isolation ----
  #
  # Storage uses Fiber[] (inheritable fiber storage) on Ruby 3.2+. The
  # production-correct behavior is:
  #   - Threads/fibers spawned INSIDE with_timeout inherit the deadline.
  #     (A job that spawns helper threads wants them bounded too.)
  #   - Threads/fibers spawned OUTSIDE with_timeout never see it.

  def test_threads_spawned_inside_block_inherit_deadline
    captured = nil
    TcpUserTimeout.with_timeout(5) do
      captured = Thread.new { TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] }.value
    end
    assert_equal 5_000, captured
  end

  def test_threads_spawned_outside_block_do_not_see_deadline
    captured = nil
    waiter = Thread.new do
      sleep 0.05
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    TcpUserTimeout.with_timeout(5) { sleep 0.1 }
    waiter.join
    assert_nil captured
  end

  def test_concurrent_with_timeout_calls_do_not_interfere
    # Two threads running with_timeout concurrently must each see only
    # their own timeout value, never the other's.
    seen_a = []
    seen_b = []
    barrier = Queue.new

    thread_a = Thread.new do
      TcpUserTimeout.with_timeout(1) do
        barrier << :a_inside
        # Wait for B to be inside its own with_timeout, then sample.
        sleep 0.01 until barrier.size >= 2
        20.times { seen_a << TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] }
      end
    end

    thread_b = Thread.new do
      TcpUserTimeout.with_timeout(60) do
        barrier << :b_inside
        sleep 0.01 until barrier.size >= 2
        20.times { seen_b << TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] }
      end
    end

    thread_a.join
    thread_b.join

    assert_equal [1_000], seen_a.uniq, 'thread A saw values other than its own timeout'
    assert_equal [60_000], seen_b.uniq, 'thread B saw values other than its own timeout'
  end

  # ---- Fiber isolation ----
  #
  # Fiber[] (Ruby 3.2+ inheritable fiber storage) gives us per-fiber state
  # that propagates to fibers spawned INSIDE with_timeout but does not leak
  # to sibling fibers created outside it.

  def test_with_timeout_in_fiber_does_not_leak_to_other_fibers
    captured = nil

    fiber_a = Fiber.new do
      TcpUserTimeout.with_timeout(5) do
        Fiber.yield
      end
    end

    fiber_b = Fiber.new do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end

    fiber_a.resume
    fiber_b.resume
    assert_nil captured, 'fiber-local timeout leaked to a sibling fiber on the same thread'

    # Resume A so its ensure block runs.
    begin
      fiber_a.resume
    rescue StandardError
      nil
    end
  end

  def test_with_timeout_in_fiber_restores_on_yield_resume_cycle
    samples = []

    fiber = Fiber.new do
      TcpUserTimeout.with_timeout(5) do
        samples << TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
        Fiber.yield
        samples << TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      end
    end

    fiber.resume
    fiber.resume
    assert_equal [5_000, 5_000], samples
  end

  # ---- Fork safety ----

  def test_install_survives_fork_and_remains_idempotent_in_child
    skip 'fork unsupported on this platform' unless Process.respond_to?(:fork)

    TcpUserTimeout.install!
    parent_count = ::Socket.singleton_class.ancestors.count(TcpUserTimeout::SocketHook)

    read_io, write_io = IO.pipe
    pid = fork do
      read_io.close
      # In the child: hooks should already be present from parent prepend.
      # Calling install! again must not double-prepend.
      already_installed = TcpUserTimeout.installed?
      TcpUserTimeout.install!
      after_count = ::Socket.singleton_class.ancestors.count(TcpUserTimeout::SocketHook)
      write_io.write("#{already_installed},#{after_count}")
      write_io.close
      exit!(0)
    end
    write_io.close
    Process.waitpid(pid)
    output = read_io.read
    read_io.close

    already_installed_in_child, child_count = output.split(',')
    assert_equal 'true', already_installed_in_child, 'install state did not survive fork'
    assert_equal parent_count.to_s, child_count, 'install! double-prepended in child'
  end

  # ---- Concurrent install ----

  def test_install_is_safe_under_concurrent_callers
    # install! is documented as idempotent. Even under concurrent first-time
    # calls, we should never end up with the hook prepended more than once.
    # We can't reset @installed to retest from-scratch concurrent installs
    # without breaking the gem's loaded state, so this asserts the
    # post-condition: call install! from N threads, count one hook.
    threads = Array.new(8) { Thread.new { TcpUserTimeout.install! } }
    threads.each(&:join)

    socket_count = ::Socket.singleton_class.ancestors.count(TcpUserTimeout::SocketHook)
    tcp_count    = ::TCPSocket.singleton_class.ancestors.count(TcpUserTimeout::TCPSocketHook)
    assert_equal 1, socket_count, 'SocketHook prepended more than once'
    assert_equal 1, tcp_count,    'TCPSocketHook prepended more than once'
  end

  # ---- Hook return-value preservation ----

  def test_hooks_preserve_super_return_value_for_socket_tcp_block_form
    TcpUserTimeout.install!
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]

    accept_thread = Thread.new do
      server.accept
    rescue StandardError
      nil
    end

    result = ::Socket.tcp('127.0.0.1', port) do |sock|
      sock.close
      :sentinel
    end
    assert_equal :sentinel, result, 'Socket.tcp block form did not return the block value'
  ensure
    accept_thread&.kill
    server&.close
  end

  def test_hooks_preserve_super_return_value_for_tcpsocket_new
    TcpUserTimeout.install!
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]

    accept_thread = Thread.new do
      server.accept
    rescue StandardError
      nil
    end

    sock = TCPSocket.new('127.0.0.1', port)
    assert_kind_of TCPSocket, sock, 'TCPSocket.new did not return a TCPSocket'
    sock.close
  ensure
    accept_thread&.kill
    server&.close
  end

  # ---- Pre-existing sockets are never rebound ----
  #
  # The hooks fire on socket *creation* — not on every socket operation.
  # A connection in the AR pool (or any persistent HTTP/Redis pool) that
  # was opened at app boot must NEVER have TCP_USER_TIMEOUT applied retroactively.
  # That's the property that makes the gem safe to drop into a Rails app
  # with long-lived pools — boot-time connections keep their original
  # behavior; only NEW sockets opened inside a with_timeout block are bound.
  def test_pre_existing_socket_is_not_rebound
    TcpUserTimeout.install!
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    accept_thread = Thread.new do
      loop do
        server.accept
      rescue StandardError
        break
      end
    end

    # Open a "pool" socket BEFORE entering the timeout scope.
    pool_socket = TCPSocket.open('127.0.0.1', port)

    seen = []
    original = TcpUserTimeout.method(:maybe_apply!)
    TcpUserTimeout.singleton_class.define_method(:maybe_apply!) do |sock, **kwargs|
      seen << sock.object_id
      original.call(sock, **kwargs)
    end

    begin
      TcpUserTimeout.with_timeout(0.5) do
        new_socket = TCPSocket.open('127.0.0.1', port)
        assert_equal false, seen.include?(pool_socket.object_id),
                     'pre-existing pool socket was rebound — would corrupt long-lived connections'
        assert_equal true, seen.include?(new_socket.object_id),
                     'newly-opened socket inside with_timeout was not bound'
        new_socket.close
      end
    ensure
      TcpUserTimeout.singleton_class.define_method(:maybe_apply!, &original)
      pool_socket.close
      accept_thread.kill
      server.close
    end
  end

  # ---- Setsockopt failure does not corrupt the socket ----

  def test_setsockopt_failure_returns_socket_unchanged
    # Simulate a platform that rejects the option. The socket should still
    # be usable — maybe_apply! must swallow ENOPROTOOPT and return nil.
    fake_sock = Object.new
    def fake_sock.setsockopt(*)
      raise Errno::EINVAL
    end
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    assert_nil TcpUserTimeout.maybe_apply!(fake_sock)
  end
end

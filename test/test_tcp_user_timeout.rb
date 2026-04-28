# frozen_string_literal: true

require "test_helper"
require "socket"
require "timeout"

class TestTcpUserTimeout < Minitest::Test
  LINUX = RUBY_PLATFORM.include?("linux")

  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @held_sockets = []
    @accept_thread = Thread.new do
      loop do
        @held_sockets << @server.accept
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  def teardown
    @accept_thread&.kill
    @held_sockets&.each { |s| s.close rescue nil }
    @server&.close rescue nil
    TcpUserTimeout.global_default_seconds = nil
    TcpUserTimeout::Storage[TcpUserTimeout::STORAGE_KEY] = nil
  end

  # ------- API -------

  def test_version_present
    refute_nil TcpUserTimeout::VERSION
  end

  def test_with_timeout_pushes_and_pops_state
    assert_nil TcpUserTimeout.current_state
    TcpUserTimeout.with_timeout(60) do
      assert_equal 60_000, TcpUserTimeout.current_state.timeout_ms
    end
    assert_nil TcpUserTimeout.current_state
  end

  def test_with_timeout_nests_and_restores_outer_state
    TcpUserTimeout.with_timeout(60) do
      assert_equal 60_000, TcpUserTimeout.current_state.timeout_ms
      TcpUserTimeout.with_timeout(5) do
        assert_equal 5_000, TcpUserTimeout.current_state.timeout_ms
      end
      assert_equal 60_000, TcpUserTimeout.current_state.timeout_ms
    end
  end

  def test_with_timeout_restores_state_on_exception
    raised = false
    begin
      TcpUserTimeout.with_timeout(10) { raise "boom" }
    rescue
      raised = true
    end
    assert raised
    assert_nil TcpUserTimeout.current_state
  end

  def test_storage_propagates_to_child_fibers_and_threads
    # Ruby 3.2+ Fiber[] inheritable storage propagates to child fibers
    # AND threads spawned inside the block. Threads spawned outside do
    # not see it.
    inside_thread = nil
    inside_fiber  = nil
    TcpUserTimeout.with_timeout(5) do
      inside_thread = Thread.new { TcpUserTimeout.current_state&.timeout_ms }.value
      inside_fiber  = Fiber.new { TcpUserTimeout.current_state&.timeout_ms }.resume
    end
    assert_equal 5_000, inside_thread
    assert_equal 5_000, inside_fiber

    outside = Thread.new { TcpUserTimeout.current_state }.value
    assert_nil outside
  end

  def test_global_default_state
    assert_nil TcpUserTimeout.current_state
    TcpUserTimeout.global_default_seconds = 7
    assert_equal 7_000, TcpUserTimeout.current_state.timeout_ms
  end

  def test_install_is_idempotent
    TcpUserTimeout.install!
    TcpUserTimeout.install!
    matches = Socket.singleton_class.ancestors.count { |a| a == TcpUserTimeout::Hook::SocketTcp }
    assert_equal 1, matches
  end

  def test_maybe_apply_swallows_unsupported_optname
    sock = Socket.new(:INET, :STREAM)
    TcpUserTimeout.with_timeout(5) do
      TcpUserTimeout.maybe_apply!(sock)
    end
    sock.close
  end

  def test_macos_is_a_silent_noop
    # On macOS / non-Linux, applying TCP_USER_TIMEOUT raises Errno::ENOPROTOOPT
    # which we rescue silently. The block runs; no exception propagates.
    skip "test runs on non-Linux platforms" if LINUX

    TcpUserTimeout.with_timeout(1) do
      sock = TCPSocket.open("127.0.0.1", @port)
      sock.close
    end
    pass
  end

  # ------- Linux-only: actual kernel-level wedge resolution -------

  def test_write_side_wedge_is_killed_at_the_deadline
    skip "TCP_USER_TIMEOUT is Linux-only" unless LINUX

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = nil
    Timeout.timeout(10, RuntimeError, "wedge not enforced — exceeded 10s") do
      err = assert_raises(StandardError) do
        TcpUserTimeout.with_timeout(1) do
          sock = TCPSocket.open("127.0.0.1", @port)
          buf = "x" * 64_000
          loop { sock.write(buf) }
        end
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.5,
      "expected ~1s, took #{elapsed.round(2)}s — got #{err.class}: #{err.message}"
    assert (Errno::ETIMEDOUT === err) || (IO::TimeoutError === err),
      "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
  end

  # ------- Adapters -------

  def test_active_job_headroom_math
    require "tcp_user_timeout/active_job"
    assert_in_delta 0.9,  TcpUserTimeout::ActiveJob.headroom_seconds(1),    0.001
    assert_in_delta 1.8,  TcpUserTimeout::ActiveJob.headroom_seconds(2),    0.001
    assert_in_delta 5.0,  TcpUserTimeout::ActiveJob.headroom_seconds(10),   0.001
    assert_in_delta 25.0, TcpUserTimeout::ActiveJob.headroom_seconds(30),   0.001
    assert_in_delta 595,  TcpUserTimeout::ActiveJob.headroom_seconds(600),  0.001
  end

  def test_rack_middleware_scopes_per_request
    require "tcp_user_timeout/rack"

    captured = nil
    app = ->(_env) {
      captured = TcpUserTimeout.current_state&.timeout_ms
      [200, {}, ["ok"]]
    }
    middleware = TcpUserTimeout::Rack::Middleware.new(app, seconds: 2)
    status, _, _ = middleware.call({})

    assert_equal 200, status
    assert_equal 2_000, captured
    assert_nil TcpUserTimeout.current_state
  end

  def test_rack_middleware_accepts_proc_for_seconds
    require "tcp_user_timeout/rack"

    captured = nil
    app = ->(_env) {
      captured = TcpUserTimeout.current_state&.timeout_ms
      [200, {}, ["ok"]]
    }
    middleware = TcpUserTimeout::Rack::Middleware.new(app, seconds: ->(env) { env["TIMEOUT_S"].to_f })
    middleware.call("TIMEOUT_S" => "0.5")
    assert_equal 500, captured
  end

  def test_rack_middleware_with_zero_seconds_skips_scope
    require "tcp_user_timeout/rack"

    captured = :sentinel
    app = ->(_env) {
      captured = TcpUserTimeout.current_state
      [200, {}, ["ok"]]
    }
    middleware = TcpUserTimeout::Rack::Middleware.new(app, seconds: 0)
    middleware.call({})
    assert_nil captured
  end

  def test_pre_existing_socket_is_not_rebound
    # Core design property: the hook fires on socket creation, not on every
    # operation. A socket opened *outside* a with_timeout block (a pool
    # connection from boot, etc.) should never have TCP_USER_TIMEOUT
    # applied to it.
    skip "kernel verification requires Linux" unless LINUX

    pool_socket = TCPSocket.open("127.0.0.1", @port)
    captured = []
    original = TcpUserTimeout.method(:maybe_apply!)
    TcpUserTimeout.define_singleton_method(:maybe_apply!) do |sock|
      captured << sock.object_id
      original.call(sock)
    end

    begin
      TcpUserTimeout.with_timeout(0.5) do
        new_sock = TCPSocket.open("127.0.0.1", @port)
        refute_includes captured, pool_socket.object_id,
          "pre-existing pool socket should not be rebound"
        assert_includes captured, new_sock.object_id
        new_sock.close
      end
    ensure
      TcpUserTimeout.define_singleton_method(:maybe_apply!, &original)
      pool_socket.close
    end
  end
end

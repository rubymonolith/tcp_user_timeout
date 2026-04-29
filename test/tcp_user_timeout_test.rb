# frozen_string_literal: true

require_relative 'test_helper'

# Core unit tests for the block API and thread-local mechanics. These run
# on every platform; they don't exercise the kernel-level TCP_USER_TIMEOUT
# behavior (that's covered by the Linux-only tests in test/linux/).
class TcpUserTimeoutTest < Minitest::Test
  def teardown
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
    TcpUserTimeout.global_default_seconds = nil
    TcpUserTimeout.exempt_hosts = []
  end

  def test_with_timeout_sets_thread_local
    TcpUserTimeout.with_timeout(5) do
      assert_equal 5_000, TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    assert_nil TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
  end

  def test_with_timeout_nests_and_restores
    TcpUserTimeout.with_timeout(60) do
      assert_equal 60_000, TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      TcpUserTimeout.with_timeout(5) do
        assert_equal 5_000, TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      end
      assert_equal 60_000, TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    assert_nil TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
  end

  def test_with_timeout_restores_on_exception
    assert_raises(ExpectedTestError) do
      TcpUserTimeout.with_timeout(10) do
        raise ExpectedTestError
      end
    end
    assert_nil TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
  end

  def test_with_timeout_rejects_non_positive
    assert_raises(ArgumentError) { TcpUserTimeout.with_timeout(0) {} }
    assert_raises(ArgumentError) { TcpUserTimeout.with_timeout(-1) {} }
  end

  def test_with_timeout_accepts_floats
    TcpUserTimeout.with_timeout(0.5) do
      assert_equal 500, TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
  end

  def test_with_timeout_propagates_to_threads_spawned_inside
    # With Fiber[]-based storage (Ruby 3.2+), threads spawned inside the
    # block inherit the deadline. This is production-correct: a job that
    # spawns helper threads to do parallel I/O wants those threads bounded
    # by the same kernel deadline as the job itself.
    captured = nil
    TcpUserTimeout.with_timeout(5) do
      captured = Thread.new { TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] }.value
    end
    assert_equal 5_000, captured
  end

  def test_with_timeout_does_not_leak_to_threads_spawned_outside
    captured = nil
    waiter = Thread.new do
      # Sleep until the main thread has entered with_timeout, then sample.
      sleep 0.05
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    TcpUserTimeout.with_timeout(5) { sleep 0.1 }
    waiter.join
    assert_nil captured, 'thread spawned outside the block must not see the deadline'
  end

  def test_global_default_ms_returns_nil_when_unset
    TcpUserTimeout.global_default_seconds = nil
    assert_nil TcpUserTimeout.global_default_ms
  end

  def test_global_default_ms_converts_seconds
    TcpUserTimeout.global_default_seconds = 60
    assert_equal 60_000, TcpUserTimeout.global_default_ms
  end

  def test_install_is_idempotent
    TcpUserTimeout.install!
    assert TcpUserTimeout.installed?
    # Calling again must not double-prepend.
    socket_ancestors_before = ::Socket.singleton_class.ancestors.count(TcpUserTimeout::SocketHook)
    TcpUserTimeout.install!
    socket_ancestors_after = ::Socket.singleton_class.ancestors.count(TcpUserTimeout::SocketHook)
    assert_equal socket_ancestors_before, socket_ancestors_after
  end

  def test_maybe_apply_silently_noops_on_unsupported_platform
    fake_sock = Object.new
    def fake_sock.setsockopt(*)
      raise Errno::ENOPROTOOPT
    end
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    # Must not raise.
    assert_nil TcpUserTimeout.maybe_apply!(fake_sock)
  end

  def test_maybe_apply_with_no_timeout_set_does_nothing
    setsockopt_called = false
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |*| setsockopt_called = true }
    # No thread-local, no global default.
    TcpUserTimeout.global_default_seconds = nil
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
    TcpUserTimeout.maybe_apply!(fake_sock)
    assert_equal false, setsockopt_called
  end

  def test_maybe_apply_uses_global_default_when_no_thread_local
    captured = nil
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |_level, _opt, value| captured = value }
    TcpUserTimeout.global_default_seconds = 60
    TcpUserTimeout.maybe_apply!(fake_sock)
    assert_equal 60_000, captured
  end

  def test_maybe_apply_thread_local_wins_over_global
    captured = nil
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |_level, _opt, value| captured = value }
    TcpUserTimeout.global_default_seconds = 60
    TcpUserTimeout.with_timeout(5) do
      TcpUserTimeout.maybe_apply!(fake_sock)
    end
    assert_equal 5_000, captured
  end

  def test_exempt_hosts_skips_string_match
    setsockopt_called = false
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |*| setsockopt_called = true }
    TcpUserTimeout.exempt_hosts = ['kafka-broker-1']
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    TcpUserTimeout.maybe_apply!(fake_sock, host: 'kafka-broker-1')
    assert_equal false, setsockopt_called
  end

  def test_exempt_hosts_skips_regexp_match
    setsockopt_called = false
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |*| setsockopt_called = true }
    TcpUserTimeout.exempt_hosts = [/redis-pubsub/]
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    TcpUserTimeout.maybe_apply!(fake_sock, host: 'redis-pubsub.internal')
    assert_equal false, setsockopt_called
  end

  def test_exempt_hosts_does_not_skip_non_matching_host
    captured = nil
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |_level, _opt, value| captured = value }
    TcpUserTimeout.exempt_hosts = [/\.internal\z/, 'kafka-broker-1']
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    TcpUserTimeout.maybe_apply!(fake_sock, host: 'api.example.com')
    assert_equal 5_000, captured
  end

  def test_exempt_hosts_does_not_partial_match_strings
    # String exempts must be exact-match — substring is not enough.
    captured = nil
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |_level, _opt, value| captured = value }
    TcpUserTimeout.exempt_hosts = ['kafka']
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    TcpUserTimeout.maybe_apply!(fake_sock, host: 'kafka-broker-1')
    assert_equal 5_000, captured
  end

  def test_exempt_hosts_with_nil_host_applies
    captured = nil
    fake_sock = Object.new
    fake_sock.define_singleton_method(:setsockopt) { |_level, _opt, value| captured = value }
    TcpUserTimeout.exempt_hosts = ['kafka-broker-1']
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = 5_000
    # No host given → exempt list does not apply.
    TcpUserTimeout.maybe_apply!(fake_sock)
    assert_equal 5_000, captured
  end
end

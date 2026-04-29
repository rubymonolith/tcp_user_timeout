# frozen_string_literal: true

require_relative '../test_helper'

# Linux-only kernel enforcement tests. These reproduce the wedge scenario
# from production: a thread parked in a blocking TCP write against a
# server that never reads. Without TCP_USER_TIMEOUT the thread sits in
# the kernel until the OS-level keepalive expires (~2 hours by default)
# or the connection is otherwise reset. With TCP_USER_TIMEOUT, the kernel
# kills the connection at the configured deadline.
#
# Skipped on macOS/BSD because the option silently no-ops there. Run via
# the bundled Dockerfile.test on dev machines:
#
#   docker build -f Dockerfile.test -t tcp_user_timeout:linux .
#   docker run --rm -v $PWD:/app -w /app tcp_user_timeout:linux \
#     bundle exec rake test:linux
class KernelEnforcementTest < Minitest::Test
  include TestHelpers

  def setup
    skip 'TCP_USER_TIMEOUT is Linux-only' unless LINUX
    TcpUserTimeout.install!
  end

  def teardown
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
    TcpUserTimeout.global_default_seconds = nil
  end

  def test_with_timeout_kills_a_wedged_write
    with_unresponsive_server do |port|
      elapsed, err = measure_wedge do
        TcpUserTimeout.with_timeout(1) do
          sock = TCPSocket.new('127.0.0.1', port)
          buf = 'x' * 64_000
          # Pump bytes until the OS receive buffer fills. Once full, the
          # next write blocks indefinitely waiting for an ACK that will
          # never come.
          loop { sock.write(buf) }
        end
      end

      assert_operator elapsed, :<, 2.5,
                      "expected wedge to die at ~1s, took #{elapsed.round(2)}s. Error: #{err.class}: #{err.message}"
      assert kernel_timeout?(err),
             "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
    end
  end

  def test_global_default_kills_a_wedged_write
    TcpUserTimeout.global_default_seconds = 1

    with_unresponsive_server do |port|
      elapsed, err = measure_wedge do
        sock = TCPSocket.new('127.0.0.1', port)
        buf = 'x' * 64_000
        loop { sock.write(buf) }
      end

      assert_operator elapsed, :<, 2.5,
                      "expected global default to fire at ~1s, took #{elapsed.round(2)}s (#{err.class})"
      assert kernel_timeout?(err),
             "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
    end
  end

  def test_in_block_tightens_below_global_default
    TcpUserTimeout.global_default_seconds = 60

    with_unresponsive_server do |port|
      elapsed, err = measure_wedge do
        TcpUserTimeout.with_timeout(1) do
          sock = TCPSocket.new('127.0.0.1', port)
          buf = 'x' * 64_000
          loop { sock.write(buf) }
        end
      end

      assert_operator elapsed, :<, 2.5,
                      "expected in-block tighten to fire at ~1s, took #{elapsed.round(2)}s (#{err.class})"
      assert kernel_timeout?(err),
             "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
    end
  end

  def test_no_timeout_set_does_not_kill_short_writes
    # Sanity check: if neither block nor global default is set, sockets
    # behave normally. We can't test "wedges forever" here without hanging
    # the suite, so we just write a small amount and confirm it doesn't
    # error out.
    with_unresponsive_server do |port|
      sock = TCPSocket.new('127.0.0.1', port)
      sock.write('hello')
      sock.close
      pass
    end
  end

  private

  # The Linux kernel returns ETIMEDOUT to the application when
  # TCP_USER_TIMEOUT fires. Ruby surfaces this as either Errno::ETIMEDOUT
  # (lower-level reads/writes) or IO::TimeoutError (Ruby 3.2+'s wrapping
  # of certain IO operations). Both are valid kernel-enforced timeouts.
  def kernel_timeout?(err)
    Errno::ETIMEDOUT === err || (defined?(IO::TimeoutError) && err.is_a?(IO::TimeoutError))
  end
end

# frozen_string_literal: true

require 'minitest/autorun'
require 'timeout'
require 'socket'
require 'tcp_user_timeout'

# A controlled exception class so we can assert restoration behavior
# in `with_timeout` without being mistaken for an environment exception.
class ExpectedTestError < StandardError; end

module TestHelpers
  LINUX = RUBY_PLATFORM.include?('linux')

  # Yields after starting a TCPServer that accepts connections but never
  # reads from them. Held connections are tracked so they can be torn down
  # after the test. Yields the port the server bound to.
  def with_unresponsive_server
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    held = []
    accept_thread = Thread.new do
      loop do
        held << server.accept
      rescue IOError, Errno::EBADF
        break
      end
    end

    yield port
  ensure
    accept_thread&.kill
    held&.each do |s|
      s.close
    rescue StandardError
      nil
    end
    begin
      server&.close
    rescue StandardError
      nil
    end
  end

  # Run a block, return [elapsed_seconds, exception_or_nil]. Wraps in an
  # outer 10s safety net so a test that fails to enforce its bound doesn't
  # hang the suite forever.
  def measure_wedge(&block)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = nil
    Timeout.timeout(10, RuntimeError, 'wedge not enforced — ran longer than 10s') do
      err = assert_raises(StandardError, &block)
    end
    [Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, err]
  end
end

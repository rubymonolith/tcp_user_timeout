# frozen_string_literal: true

require_relative '../test_helper'
require 'tcp_user_timeout/middleware'

# End-to-end test that the Rack middleware enforces its bound at the
# kernel level. Linux-only — see test/linux/ for why.
class MiddlewareKernelTest < Minitest::Test
  include TestHelpers

  def setup
    skip 'TCP_USER_TIMEOUT is Linux-only' unless LINUX
    TcpUserTimeout.install!
  end

  def test_request_timeout_kills_wedged_outbound_call
    with_unresponsive_server do |port|
      app = lambda do |_env|
        sock = TCPSocket.new('127.0.0.1', port)
        buf = 'x' * 64_000
        loop { sock.write(buf) }
      end
      middleware = TcpUserTimeout::Middleware.new(app, timeout: 1)

      elapsed, err = measure_wedge { middleware.call({}) }

      assert_operator elapsed, :<, 2.5,
                      "expected middleware bound to fire at ~1s, took #{elapsed.round(2)}s (#{err.class})"
      assert Errno::ETIMEDOUT === err || (defined?(IO::TimeoutError) && err.is_a?(IO::TimeoutError)),
             "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
    end
  end
end

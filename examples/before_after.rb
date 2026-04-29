# frozen_string_literal: true

# Demo: the wedge problem and the fix.
#
# Run on a Linux box (or in the included Dockerfile.test) to see the
# difference. On macOS this script silently no-ops the option and the
# "after" case wedges just like the "before" case — that's by design.
#
# Usage:
#   ruby examples/before_after.rb before  # hangs
#   ruby examples/before_after.rb after   # dies in ~1s
#
# Inside Docker (recommended on macOS dev):
#   docker run --rm -v $PWD:/app -w /app tcp_user_timeout:linux \
#     ruby examples/before_after.rb after

require 'socket'
require 'tcp_user_timeout'

mode = ARGV[0] || 'after'

server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
puts "server listening on 127.0.0.1:#{port}"

# Server accepts but never reads. Client writes will block once the OS
# receive buffer fills.
Thread.new do
  loop do
    server.accept
  rescue IOError, Errno::EBADF
    break
  end
end

case mode
when 'before'
  # No TCP_USER_TIMEOUT. Once the OS receive buffer fills, this thread
  # parks in the kernel waiting for an ACK that will never come. Default
  # TCP keepalive doesn't fire for ~2 hours.
  sock = TCPSocket.new('127.0.0.1', port)
  buf = 'x' * 64_000
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    loop { sock.write(buf) }
  rescue StandardError => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts "got #{e.class} after #{elapsed.round(1)}s"
  end

when 'after'
  # With TcpUserTimeout.with_timeout(1), the kernel enforces a 1-second
  # deadline. ETIMEDOUT raises within ~1s.
  TcpUserTimeout.install!
  TcpUserTimeout.with_timeout(1) do
    sock = TCPSocket.new('127.0.0.1', port)
    buf = 'x' * 64_000
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      loop { sock.write(buf) }
    rescue StandardError => e
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "got #{e.class}: #{e.message} after #{elapsed.round(1)}s"
    end
  end

else
  puts 'Usage: ruby examples/before_after.rb [before|after]'
  exit 1
end

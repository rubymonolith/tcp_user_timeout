# frozen_string_literal: true

require "socket"
require_relative "tcp_user_timeout/version"
require_relative "tcp_user_timeout/storage"
require_relative "tcp_user_timeout/hook"

# Kernel-enforced socket deadlines on Linux via TCP_USER_TIMEOUT.
#
#   TcpUserTimeout.with_timeout(30) do
#     Net::HTTP.get(URI("https://upstream.example/slow"))
#   end
#
# Sockets opened *inside* the block get TCP_USER_TIMEOUT applied. The
# Linux kernel forcibly closes the connection when transmitted data has
# been unacknowledged for the configured time, raising Errno::ETIMEDOUT
# / IO::TimeoutError from the next blocking syscall. Catches write-side
# wedges and network partitions.
#
# Pre-existing sockets — DB pools, persistent HTTP pools created at boot
# — are never re-bound. Only sockets created inside the block inherit the
# deadline.
#
# Platform support:
#   - Linux: enforced by the kernel.
#   - Other platforms (macOS, BSD, Windows): silent no-op. setsockopt
#     raises Errno::ENOPROTOOPT (or similar) and is rescued. There is no
#     direct equivalent of TCP_USER_TIMEOUT on macOS.
#
# What this does NOT cover:
#   - Read-side wedges where the peer's userspace is wedged but its
#     kernel is responsive. TCP_USER_TIMEOUT does not fire because the
#     peer kernel auto-ACKs packets even when its application is stuck.
#     For those wedges use application-level timeouts (Net::HTTP
#     read_timeout, IO#timeout=, SDK-specific request timeouts).
#   - FFI / libcurl-based HTTP clients (curb, etc.) — bypass Ruby's
#     socket layer entirely.
#   - DNS (getaddrinfo). Mitigate via resolv.conf.
#   - Connect phase. Use Net::HTTP#open_timeout / libpq connect_timeout.
module TcpUserTimeout
  class Error < StandardError; end

  # TCP_USER_TIMEOUT optname from <linux/tcp.h>. Hardcoded because
  # Socket::TCP_USER_TIMEOUT is not exposed on every Ruby version.
  TCP_USER_TIMEOUT_OPT = 18

  STORAGE_KEY = :tcp_user_timeout_state

  State = Struct.new(:timeout_seconds) do
    def timeout_ms
      (timeout_seconds.to_f * 1000).to_i
    end
  end

  class << self
    # Optional ceiling applied to every outbound TCP socket created when
    # no with_timeout block is in effect. nil disables the global default.
    attr_accessor :global_default_seconds
  end
  self.global_default_seconds = nil

  module_function

  # Bound sockets opened inside the block to `seconds`.
  def with_timeout(seconds)
    install!
    state = State.new(seconds.to_f)
    prev = Storage[STORAGE_KEY]
    Storage[STORAGE_KEY] = state
    yield
  ensure
    Storage[STORAGE_KEY] = prev
  end

  # Apply the currently-scoped state (or the global default) to a socket.
  # Silently no-ops on platforms / sockets that don't support the option.
  def maybe_apply!(socket)
    state = current_state
    return unless state && state.timeout_ms > 0
    socket.setsockopt(::Socket::IPPROTO_TCP, TCP_USER_TIMEOUT_OPT, state.timeout_ms)
  rescue Errno::ENOPROTOOPT, Errno::EINVAL, Errno::ENOTSOCK, Errno::EBADF
    nil
  end

  # Idempotent installation of Socket / TCPSocket prepend hooks.
  def install!
    return if @installed
    ::Socket.singleton_class.prepend(Hook::SocketTcp)
    ::TCPSocket.singleton_class.prepend(Hook::TCPSocketSingleton)
    @installed = true
  end

  def installed?
    @installed == true
  end

  # Public for testing and instrumentation.
  def current_state
    Storage[STORAGE_KEY] || global_default_state
  end

  class << self
    private

    def global_default_state
      seconds = global_default_seconds
      return nil unless seconds && seconds > 0
      State.new(seconds.to_f)
    end
  end
end

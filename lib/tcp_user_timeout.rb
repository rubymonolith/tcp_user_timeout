# frozen_string_literal: true

require 'socket'

require_relative 'tcp_user_timeout/version'
require_relative 'tcp_user_timeout/storage'

# Sets TCP_USER_TIMEOUT on outbound TCP sockets so the Linux kernel drops
# connections that have stopped making forward progress. The kernel — not
# Ruby, not a watchdog — closes the connection at the deadline and returns
# ETIMEDOUT to userspace, freeing whatever Ruby thread was parked in the
# blocking syscall.
#
# Linux only. macOS and other non-Linux platforms silently no-op via
# Errno::ENOPROTOOPT (dev work unaffected).
#
#   TcpUserTimeout.install!
#   TcpUserTimeout.with_timeout(30) do
#     Net::HTTP.get(URI("https://example.com"))
#   end
#
# See the Linux man page tcp(7) for the underlying primitive:
#   https://man7.org/linux/man-pages/man7/tcp.7.html
module TcpUserTimeout
  # TCP_USER_TIMEOUT optname from <linux/tcp.h>. Hardcoded because
  # `Socket::TCP_USER_TIMEOUT` isn't exposed across all Ruby versions
  # and platforms.
  OPTNAME = 18

  THREAD_KEY = :tcp_user_timeout_ms

  class << self
    # Optional ceiling applied to every outbound TCP socket when no
    # per-block timeout is in effect. nil disables the global default.
    attr_accessor :global_default_seconds

    # Hosts (Strings, exact-match) or patterns (Regexp, =~ match) that
    # should NOT have TCP_USER_TIMEOUT applied. Useful for connections
    # where idle gaps are legitimate (long-poll, message-broker
    # subscriptions) or where the client manages its own timeout config
    # at a higher level (e.g., libpq's `tcp_user_timeout` parameter).
    #
    #   TcpUserTimeout.exempt_hosts = [
    #     /\.internal\z/,         # internal mesh
    #     "kafka-broker-1",       # specific host
    #     /redis-pubsub/          # subscriber connections
    #   ]
    attr_accessor :exempt_hosts
  end
  self.exempt_hosts = []

  # Run `block` with TCP_USER_TIMEOUT scoped to `seconds` for any socket
  # opened via Socket.tcp / TCPSocket.new / TCPSocket.open inside the block.
  # Restores the previous value (or nil) on block exit, including on exception.
  #
  # Nesting is supported — inner blocks override outer for the duration of
  # the inner.
  def self.with_timeout(seconds)
    raise ArgumentError, 'seconds must be positive' unless seconds.to_f.positive?

    prev = Storage[THREAD_KEY]
    Storage[THREAD_KEY] = (seconds.to_f * 1000).to_i
    yield
  ensure
    Storage[THREAD_KEY] = prev
  end

  # Apply the currently-scoped timeout (or the global default) to a socket.
  # Silently no-ops on platforms / sockets that don't support the option,
  # and on hosts matching `exempt_hosts`.
  def self.maybe_apply!(socket, host: nil)
    return if host && exempt?(host)

    ms = Storage[THREAD_KEY] || global_default_ms
    return unless ms&.positive?

    socket.setsockopt(::Socket::IPPROTO_TCP, OPTNAME, ms)
    nil
  rescue Errno::ENOPROTOOPT, Errno::EINVAL, Errno::ENOTSOCK, Errno::EBADF
    # Non-Linux platform, socket already closed, not actually a socket, or
    # in a state where setsockopt rejects this option. Either way: nothing
    # we can do, don't blow up.
    nil
  end

  # Returns true if `host` matches any pattern in `exempt_hosts`.
  def self.exempt?(host)
    return false if exempt_hosts.empty?

    host_str = host.to_s
    exempt_hosts.any? do |pattern|
      pattern.is_a?(Regexp) ? pattern.match?(host_str) : pattern.to_s == host_str
    end
  end

  # Install the Socket / TCPSocket prepend hooks. Idempotent.
  #
  # Call this once at app boot. For Rails apps, the bundled Railtie does
  # this for you (require "tcp_user_timeout/railtie" or just have Rails
  # load the gem normally).
  def self.install!
    return if @installed

    ::Socket.singleton_class.prepend(SocketHook)
    ::TCPSocket.singleton_class.prepend(TCPSocketHook)
    @installed = true
  end

  def self.installed?
    @installed == true
  end

  # Internal: convert global_default_seconds to milliseconds.
  def self.global_default_ms
    seconds = global_default_seconds
    seconds && (seconds.to_f * 1000).to_i
  end

  # The TCP_USER_TIMEOUT we set should be slightly less than the declared
  # deadline so the kernel kills the socket *before* any outer guard fires.
  # At production scales (≥10s) we reserve a 5s headroom; below that we use
  # 90% of max so very short timeouts in tests still get enforced.
  #
  # This is the same math used by ActiveJob::MaxExecutionTime and the
  # Sidekiq middleware. Exposed at the top level so integrations don't
  # need to depend on ActiveJob just to get the headroom rule.
  def self.headroom_seconds(max)
    max_f = max.to_f
    max_f >= 10 ? max_f - 5 : max_f * 0.9
  end

  # Hook around Socket.tcp. Both block and non-block forms are supported.
  # Host is captured from the call args so the exempt list can match.
  module SocketHook
    def tcp(host, port, *args, **kwargs, &block)
      if block
        super(host, port, *args, **kwargs) do |sock|
          TcpUserTimeout.maybe_apply!(sock, host: host)
          yield(sock)
        end
      else
        sock = super(host, port, *args, **kwargs)
        TcpUserTimeout.maybe_apply!(sock, host: host)
        sock
      end
    end
  end

  # Hook around TCPSocket.new and TCPSocket.open. `new` is the constructor
  # most code (including TCPSocket.open) ultimately goes through, so hooking
  # both ensures broad coverage even for paths that bypass `open`.
  module TCPSocketHook
    def open(*args, **kwargs)
      sock = super
      TcpUserTimeout.maybe_apply!(sock, host: args.first)
      sock
    end

    def new(*args, **kwargs)
      sock = super
      TcpUserTimeout.maybe_apply!(sock, host: args.first)
      sock
    end
  end
end

# Auto-install if Rails is present. Non-Rails apps must call
# TcpUserTimeout.install! explicitly.
require_relative 'tcp_user_timeout/railtie' if defined?(Rails::Railtie)

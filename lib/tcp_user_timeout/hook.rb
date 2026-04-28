# frozen_string_literal: true

require "socket"

module TcpUserTimeout
  # Prepend hooks on Socket / TCPSocket that apply the currently-scoped
  # TCP_USER_TIMEOUT (and optional keepalive params) to newly created
  # outbound TCP sockets. Pre-existing sockets — including DB / HTTP pool
  # connections created at boot — are never re-bound; they pass through
  # the hook only on the call that created them.
  module Hook
    module SocketTcp
      def tcp(host, port, *args, **kwargs, &block)
        if block
          super(host, port, *args, **kwargs) do |sock|
            TcpUserTimeout.maybe_apply!(sock)
            block.call(sock)
          end
        else
          sock = super(host, port, *args, **kwargs)
          TcpUserTimeout.maybe_apply!(sock)
          sock
        end
      end
    end

    module TCPSocketSingleton
      def open(*args, **kwargs)
        sock = super
        TcpUserTimeout.maybe_apply!(sock)
        sock
      end

      # TCPSocket.new is the underlying constructor — covers paths that
      # bypass `open`. Explicit hook because `open` is sometimes an alias
      # for `new` and sometimes its own method depending on Ruby version.
      def new(*args, **kwargs)
        sock = super
        TcpUserTimeout.maybe_apply!(sock)
        sock
      end
    end
  end
end

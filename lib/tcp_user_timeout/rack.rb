# frozen_string_literal: true

require_relative "../tcp_user_timeout"

module TcpUserTimeout
  module Rack
    # Rack middleware that scopes TCP_USER_TIMEOUT to the duration of each
    # request. Only sockets *opened during the request* get the deadline —
    # pre-existing pooled connections (DB, persistent HTTP) created at app
    # boot are untouched, so production pools that should outlive any
    # single request keep their original behavior.
    #
    #   use TcpUserTimeout::Rack::Middleware, seconds: 25
    #
    #   # Or, derive the bound from each request (e.g. from a header):
    #   use TcpUserTimeout::Rack::Middleware, seconds: ->(env) {
    #     env["HTTP_X_REQUEST_TIMEOUT_S"]&.to_f || 25
    #   }
    #
    # Recommended setup: pick a value slightly under the web server's
    # worker-kill timeout (Puma's `worker_timeout`, Heroku's 30s router
    # cap, etc.) so the kernel kills wedged sockets before the worker is
    # SIGKILL'd. Defaults to off — you must opt in.
    class Middleware
      def initialize(app, seconds:)
        @app = app
        @seconds = seconds
      end

      def call(env)
        seconds = @seconds.respond_to?(:call) ? @seconds.call(env) : @seconds
        return @app.call(env) unless seconds && seconds > 0

        TcpUserTimeout.with_timeout(seconds) { @app.call(env) }
      end
    end
  end
end

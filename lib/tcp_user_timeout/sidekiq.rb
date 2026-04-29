# frozen_string_literal: true

require 'tcp_user_timeout'

# Sidekiq integration. Sidekiq doesn't use ActiveJob by default, so the
# bounding mechanism here is a server-side middleware: every job runs inside
# a `TcpUserTimeout.with_timeout` block scoped to whichever deadline the
# worker class declares.
#
# Usage:
#
#   # config/initializers/sidekiq.rb
#   require "tcp_user_timeout/sidekiq"
#
#   class MyWorker
#     include Sidekiq::Worker
#     sidekiq_options max_execution_time: 30
#
#     def perform(...)
#       # any TCP socket opened here gets TCP_USER_TIMEOUT = 25s (5s headroom)
#     end
#   end
#
# Workers without `max_execution_time` set are unaffected — the middleware
# is a no-op for them. Set `TcpUserTimeout.global_default_seconds` for a
# global ceiling that applies to every job regardless of declaration.
#
# If you also use ActiveJob on top of Sidekiq, you can additionally
# `require "active_job/max_execution_time"` and include the concern into
# ApplicationJob — both layers compose (innermost wins via with_timeout
# nesting).
module TcpUserTimeout
  module Sidekiq
    # Server middleware. Reads `max_execution_time` from the worker's
    # sidekiq_options and wraps `perform` in `TcpUserTimeout.with_timeout`.
    class ServerMiddleware
      def call(_worker, job, _queue, &block)
        seconds = job['max_execution_time'] || job[:max_execution_time]

        if seconds.to_f.positive?
          headroom = TcpUserTimeout.headroom_seconds(seconds.to_f)
          TcpUserTimeout.with_timeout(headroom, &block)
        else
          yield
        end
      end
    end
  end
end

TcpUserTimeout.install!

if defined?(::Sidekiq)
  ::Sidekiq.configure_server do |config|
    config.server_middleware do |chain|
      chain.add TcpUserTimeout::Sidekiq::ServerMiddleware
    end
  end
end

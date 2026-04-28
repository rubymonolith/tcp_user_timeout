# frozen_string_literal: true

require "active_support/concern"
require_relative "../tcp_user_timeout"

module TcpUserTimeout
  # Mix into ActiveJob jobs to enforce a per-job deadline:
  #
  #   class FetchUpstreamJob < ApplicationJob
  #     include TcpUserTimeout::ActiveJob
  #     self.max_execution_time = 30.seconds
  #     self.tcp_user_timeout_keepalive = true   # opt in for read-side coverage
  #
  #     def perform(url)
  #       Net::HTTP.get(URI(url))
  #     end
  #   end
  #
  # Sockets opened during `perform` get TCP_USER_TIMEOUT bounded by the
  # max_execution_time (with a small headroom so the kernel fires before
  # any outer guard). Pre-existing connections (the AR pool, persistent
  # HTTP pools) are not touched — only what the job opens itself.
  module ActiveJob
    extend ::ActiveSupport::Concern

    included do
      class_attribute :max_execution_time, instance_accessor: false

      around_perform do |job, block|
        if (max = job.class.max_execution_time)
          TcpUserTimeout.with_timeout(
            TcpUserTimeout::ActiveJob.headroom_seconds(max)
          ) { block.call }
        else
          block.call
        end
      end
    end

    # Reserve a small buffer below max_execution_time so the kernel
    # closes the socket before any outer guard (Sidekiq's job-killer,
    # SolidQueue's watchdog, etc.). 5s headroom at production scales
    # (>=10s); 90% of max below that so short timeouts in tests still
    # land below the deadline.
    def self.headroom_seconds(max)
      max_f = max.to_f
      max_f >= 10 ? max_f - 5 : max_f * 0.9
    end
  end
end

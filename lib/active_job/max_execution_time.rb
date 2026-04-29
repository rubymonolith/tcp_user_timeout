# frozen_string_literal: true

require 'tcp_user_timeout'

module ActiveJob
  # Declares an enforced upper bound on a job's wall-clock execution time.
  # When set, every TCP socket opened during `perform` gets TCP_USER_TIMEOUT
  # so the Linux kernel forcibly closes wedged connections at the deadline,
  # which is the only thing that can free a Ruby thread parked in a kernel
  # syscall (Thread#kill and Timeout.timeout cannot — they set a flag the
  # blocked thread never reads).
  #
  #   class FetchUpstreamJob < ApplicationJob
  #     include ActiveJob::MaxExecutionTime
  #     self.max_execution_time = 30.seconds
  #
  #     def perform(url)
  #       Net::HTTP.get(URI(url))
  #     end
  #   end
  #
  # Or, to apply it to every job in your app:
  #
  #   class ApplicationJob < ActiveJob::Base
  #     include ActiveJob::MaxExecutionTime
  #   end
  #
  # If you're using SolidQueue, requiring "tcp_user_timeout/solid_queue"
  # includes this concern into ActiveJob::Base for you.
  module MaxExecutionTime
    extend ActiveSupport::Concern

    included do
      class_attribute :max_execution_time, instance_accessor: false

      around_perform do |job, block|
        if (max = job.class.max_execution_time)
          TcpUserTimeout.with_timeout(TcpUserTimeout.headroom_seconds(max)) { block.call }
        else
          block.call
        end
      end
    end

    # Backwards-compatible alias for callers that referenced the headroom
    # math here. Canonical implementation lives on TcpUserTimeout.
    def self.headroom_seconds(max)
      TcpUserTimeout.headroom_seconds(max)
    end
  end
end

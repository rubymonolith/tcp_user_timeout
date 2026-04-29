# frozen_string_literal: true

require 'tcp_user_timeout'
require 'active_job'
require 'active_job/max_execution_time'

# SolidQueue integration. Requiring this file:
#
#   1. Ensures the TCP_USER_TIMEOUT Socket hooks are installed (via the
#      Railtie if Rails is present, or via TcpUserTimeout.install! otherwise).
#   2. Includes ActiveJob::MaxExecutionTime into ActiveJob::Base so any job
#      that declares `self.max_execution_time = N.seconds` gets its TCP I/O
#      bounded by the Linux kernel at the deadline.
#
#   # In your Gemfile or an initializer:
#   require "tcp_user_timeout/solid_queue"
#
# This makes max_execution_time an enforced contract rather than just an
# alerting threshold (which is all SolidQueue's built-in max_execution_time
# observability provides on its own).
TcpUserTimeout.install!

ActiveSupport.on_load :active_job do
  include ActiveJob::MaxExecutionTime
end

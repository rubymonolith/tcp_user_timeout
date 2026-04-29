# frozen_string_literal: true

require_relative '../test_helper'

require 'active_job'
require 'active_job/max_execution_time'

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(IO::NULL)

class ActiveJobMaxExecutionTimeTest < Minitest::Test
  def teardown
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
  end

  def test_around_perform_wraps_in_with_timeout_when_declared
    captured = nil
    base = ActiveJob::Base
    job_class = Class.new(base) do
      include ActiveJob::MaxExecutionTime
      self.max_execution_time = 30
    end
    job_class.send(:define_method, :perform) do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end

    job_class.perform_now
    # 30s with the production headroom (max - 5) = 25s = 25_000 ms
    assert_equal 25_000, captured
  end

  def test_around_perform_skips_when_undeclared
    captured = :unset
    base = ActiveJob::Base
    job_class = Class.new(base) do
      include ActiveJob::MaxExecutionTime
    end
    job_class.send(:define_method, :perform) do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end

    job_class.perform_now
    assert_nil captured
  end

  def test_headroom_at_production_scale_reserves_5_seconds
    assert_in_delta 5.0,  ActiveJob::MaxExecutionTime.headroom_seconds(10),  0.001
    assert_in_delta 25.0, ActiveJob::MaxExecutionTime.headroom_seconds(30),  0.001
    assert_in_delta 85.0, ActiveJob::MaxExecutionTime.headroom_seconds(90),  0.001
    assert_in_delta 595,  ActiveJob::MaxExecutionTime.headroom_seconds(600), 0.001
  end

  def test_headroom_below_10_seconds_uses_90_percent
    # Tests with very short timeouts must still get a kernel deadline
    # below the test's outer guard. 1s -> 0.9s, 2s -> 1.8s, etc.
    assert_in_delta 0.9, ActiveJob::MaxExecutionTime.headroom_seconds(1), 0.001
    assert_in_delta 1.8, ActiveJob::MaxExecutionTime.headroom_seconds(2), 0.001
    assert_in_delta 9.0, ActiveJob::MaxExecutionTime.headroom_seconds(9.999), 0.01
  end
end

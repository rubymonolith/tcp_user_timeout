# frozen_string_literal: true

require_relative 'test_helper'

require 'tcp_user_timeout/sidekiq'

# Minimal middleware unit tests. We don't load actual Sidekiq — the middleware
# only needs the job hash and a block, which we synthesize directly.
class TcpUserTimeoutSidekiqMiddlewareTest < Minitest::Test
  def teardown
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
  end

  def test_wraps_perform_when_max_execution_time_present_string_key
    middleware = TcpUserTimeout::Sidekiq::ServerMiddleware.new
    captured = nil
    middleware.call(:fake_worker, { 'max_execution_time' => 30 }, :default) do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    # 30s with 5s headroom = 25s = 25_000 ms
    assert_equal 25_000, captured
  end

  def test_wraps_perform_when_max_execution_time_present_symbol_key
    middleware = TcpUserTimeout::Sidekiq::ServerMiddleware.new
    captured = nil
    middleware.call(:fake_worker, { max_execution_time: 30 }, :default) do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    assert_equal 25_000, captured
  end

  def test_skips_when_max_execution_time_absent
    middleware = TcpUserTimeout::Sidekiq::ServerMiddleware.new
    captured = :unset
    middleware.call(:fake_worker, {}, :default) do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    assert_nil captured
  end

  def test_skips_when_max_execution_time_zero
    middleware = TcpUserTimeout::Sidekiq::ServerMiddleware.new
    captured = :unset
    middleware.call(:fake_worker, { 'max_execution_time' => 0 }, :default) do
      captured = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
    end
    assert_nil captured
  end

  def test_restores_thread_local_after_perform
    middleware = TcpUserTimeout::Sidekiq::ServerMiddleware.new
    middleware.call(:fake_worker, { 'max_execution_time' => 10 }, :default) { :ok }
    assert_nil TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
  end
end

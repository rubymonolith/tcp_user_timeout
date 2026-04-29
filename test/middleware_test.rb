# frozen_string_literal: true

require_relative 'test_helper'
require 'tcp_user_timeout/middleware'

class TcpUserTimeoutMiddlewareTest < Minitest::Test
  def teardown
    TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY] = nil
  end

  def test_wraps_app_in_with_timeout
    captured_timeout = nil
    app = lambda { |_env|
      captured_timeout = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      [200, {}, ['ok']]
    }
    middleware = TcpUserTimeout::Middleware.new(app, timeout: 30)
    middleware.call({})
    assert_equal 30_000, captured_timeout
  end

  def test_clears_thread_local_after_request
    app = ->(_env) { [200, {}, ['ok']] }
    middleware = TcpUserTimeout::Middleware.new(app, timeout: 30)
    middleware.call({})
    assert_nil TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
  end

  def test_clears_thread_local_after_exception
    app = ->(_env) { raise ExpectedTestError }
    middleware = TcpUserTimeout::Middleware.new(app, timeout: 30)
    assert_raises(ExpectedTestError) { middleware.call({}) }
    assert_nil TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
  end

  def test_skips_when_env_flag_set
    captured_timeout = :unset
    app = lambda { |_env|
      captured_timeout = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      [200, {}, ['ok']]
    }
    middleware = TcpUserTimeout::Middleware.new(app, timeout: 30)
    middleware.call('tcp_user_timeout.skip' => true)
    assert_nil captured_timeout
  end

  def test_default_timeout
    captured_timeout = nil
    app = lambda { |_env|
      captured_timeout = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      [200, {}, ['ok']]
    }
    middleware = TcpUserTimeout::Middleware.new(app)
    middleware.call({})
    expected_ms = (TcpUserTimeout::Middleware::DEFAULT_TIMEOUT_SECONDS * 1000).to_i
    assert_equal expected_ms, captured_timeout
  end

  def test_rejects_non_positive_timeout
    app = ->(_env) { [200, {}, ['ok']] }
    assert_raises(ArgumentError) { TcpUserTimeout::Middleware.new(app, timeout: 0) }
    assert_raises(ArgumentError) { TcpUserTimeout::Middleware.new(app, timeout: -5) }
  end

  def test_callable_timeout_evaluated_per_request
    captured_timeout = nil
    app = lambda { |_env|
      captured_timeout = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      [200, {}, ['ok']]
    }
    middleware = TcpUserTimeout::Middleware.new(
      app,
      timeout: ->(env) { env['HTTP_X_TIMEOUT_S']&.to_f || 30 }
    )
    middleware.call('HTTP_X_TIMEOUT_S' => '0.5')
    assert_equal 500, captured_timeout
  end

  def test_callable_timeout_returning_nil_skips_scope
    captured_timeout = :unset
    app = lambda { |_env|
      captured_timeout = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      [200, {}, ['ok']]
    }
    middleware = TcpUserTimeout::Middleware.new(app, timeout: ->(_env) { nil })
    middleware.call({})
    assert_nil captured_timeout
  end

  def test_callable_timeout_returning_zero_skips_scope
    captured_timeout = :unset
    app = lambda { |_env|
      captured_timeout = TcpUserTimeout::Storage[TcpUserTimeout::THREAD_KEY]
      [200, {}, ['ok']]
    }
    middleware = TcpUserTimeout::Middleware.new(app, timeout: ->(_env) { 0 })
    middleware.call({})
    assert_nil captured_timeout
  end
end

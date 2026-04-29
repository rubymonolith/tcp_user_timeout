# frozen_string_literal: true

module TcpUserTimeout
  # Rack middleware that bounds every request's outbound TCP I/O at a
  # configured deadline. Any TCP socket opened during the request — by
  # controllers, gems, the Anthropic SDK, libpq, Redis, anything that goes
  # through Ruby's socket layer — gets TCP_USER_TIMEOUT set to the
  # middleware's timeout.
  #
  # Set the timeout below your web server's request kill threshold (Puma's
  # `worker_timeout`, Falcon's deadline, NGINX's `proxy_read_timeout`) so
  # the kernel-level kill happens before the supervisor takes the worker
  # down. See README for the math.
  #
  #   # config/application.rb
  #   config.middleware.use TcpUserTimeout::Middleware, timeout: 30
  #
  # `timeout:` may also be a callable, evaluated per request — useful when
  # the bound depends on the request itself (a header, a route, etc):
  #
  #   config.middleware.use TcpUserTimeout::Middleware,
  #     timeout: ->(env) { env["HTTP_X_REQUEST_TIMEOUT_S"]&.to_f || 30 }
  #
  # If the callable returns nil or a non-positive number, the middleware
  # passes the request through without scoping a timeout (use this to skip
  # the bound for streaming/SSE/long-poll endpoints).
  #
  # Skip the bound for specific requests by setting an env flag in an
  # earlier middleware:
  #
  #   env["tcp_user_timeout.skip"] = true
  class Middleware
    DEFAULT_TIMEOUT_SECONDS = 30

    def initialize(app, timeout: DEFAULT_TIMEOUT_SECONDS)
      @app = app
      @timeout = timeout
      # Validate fixed numeric values up front. Callables are evaluated
      # per-request, so they're checked at call time.
      return if @timeout.respond_to?(:call)
      raise ArgumentError, 'timeout must be positive' unless @timeout.to_f.positive?
    end

    def call(env)
      return @app.call(env) if env['tcp_user_timeout.skip']

      seconds = @timeout.respond_to?(:call) ? @timeout.call(env) : @timeout
      return @app.call(env) unless seconds&.to_f&.positive?

      TcpUserTimeout.with_timeout(seconds.to_f) { @app.call(env) }
    end
  end
end

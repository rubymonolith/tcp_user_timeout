# frozen_string_literal: true

require 'rails/railtie'

module TcpUserTimeout
  # Rails integration: installs Socket hooks at boot so every TCP socket
  # opened by the app, its dependencies, and its background workers is
  # subject to whatever TCP_USER_TIMEOUT is currently scoped (per-block or
  # global default).
  #
  # Configure in an initializer:
  #
  #   # config/initializers/tcp_user_timeout.rb
  #   TcpUserTimeout.global_default_seconds = 600  # 10 minute safety net
  #
  # Or scope per-call:
  #
  #   TcpUserTimeout.with_timeout(30) { Net::HTTP.get(uri) }
  #
  # Or wrap every web request via the bundled middleware:
  #
  #   # config/application.rb
  #   config.middleware.use TcpUserTimeout::Middleware, timeout: 30
  class Railtie < ::Rails::Railtie
    initializer 'tcp_user_timeout.install' do
      TcpUserTimeout.install!
    end
  end
end

# Changelog

All notable changes to `tcp_user_timeout` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-04-28

Initial release.

### Added

- `TcpUserTimeout.with_timeout(seconds) { ... }` block API. Any TCP socket opened inside the block gets `TCP_USER_TIMEOUT` set so the Linux kernel forcibly closes the connection if it stops making forward progress past the deadline.
- `TcpUserTimeout.global_default_seconds` for an app-wide ceiling on every outbound TCP socket.
- `TcpUserTimeout.install!` (idempotent) for explicit Socket / TCPSocket hook installation in non-Rails apps.
- `TcpUserTimeout::Railtie` for Rails apps — auto-installs the hooks at boot.
- `TcpUserTimeout::Middleware` — Rack middleware that wraps every web request in a timeout. Recommended bound: just below the web server's worker timeout (Puma's `worker_timeout`, Falcon's deadline, NGINX's `proxy_read_timeout`).
- `ActiveJob::MaxExecutionTime` concern — declare `self.max_execution_time = N.seconds` on a job class and every TCP socket the job opens during `perform` is bounded to `N - 5s` (or 90% of `N` for short timeouts).
- `tcp_user_timeout/solid_queue` integration entrypoint — `require` it once and every ActiveJob in your app gains the `max_execution_time` enforcement.
- `tcp_user_timeout/sidekiq` integration — server middleware that reads `max_execution_time` from `sidekiq_options` and wraps `perform` in `with_timeout` with the standard headroom math. Does not depend on ActiveJob.
- `TcpUserTimeout.exempt_hosts` — array of Strings (exact match) and/or Regexps to skip. For long-poll, message-broker subscribers, Action Cable, SSE, and other connections where idle gaps are legitimate.
- `TcpUserTimeout.headroom_seconds(max)` — canonical implementation of the production headroom rule (5s reserve at ≥10s, 90% below). Used by both the ActiveJob concern and the Sidekiq middleware. `ActiveJob::MaxExecutionTime.headroom_seconds` is now a thin alias.
- Linux-only kernel enforcement tests under `test/linux/`. Run via the included `Dockerfile.test` from macOS dev.
- Safety test suite (`test/safety_test.rb`) covering thread isolation, fiber isolation, fork survival, concurrent install idempotence, hook return-value preservation, and the load-bearing "pre-existing sockets are never rebound" property.
- `TcpUserTimeout::Storage` — fiber-inheritable state (`Fiber[]` on Ruby 3.2+) so child threads/fibers spawned inside `with_timeout` inherit the deadline. Falls back to `Thread.current[]` on older Rubies.
- Rack middleware `timeout:` accepts a callable: `timeout: ->(env) { env["HTTP_X_TIMEOUT_S"]&.to_f || 30 }`. Returning nil or 0 from the callable skips the scope (use this to bypass on streaming/SSE endpoints).
- Defensive `Errno::ENOTSOCK` and `Errno::EBADF` are now also rescued from `setsockopt` — covers sockets in unusual states (already closed, not actually a socket).

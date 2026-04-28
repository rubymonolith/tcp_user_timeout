# tcp_user_timeout

Kernel-enforced socket deadlines on Linux via `TCP_USER_TIMEOUT`. Sockets opened *inside* a `with_timeout` block are forcibly closed by the kernel if transmitted data goes unacknowledged longer than the deadline. Pre-existing sockets — DB pools, persistent HTTP pools created at app boot — are never re-bound.

```ruby
TcpUserTimeout.with_timeout(30) do
  Net::HTTP.get(URI("https://upstream.example/slow"))
end
```

If the upstream stops ACKing, the kernel closes the connection at ~30s and the next read or write raises `Errno::ETIMEDOUT` / `IO::TimeoutError`. The thread is freed even if it was parked in a syscall — the case `Thread#kill` and `Timeout.timeout` cannot handle.

## What this covers

- **Write-side wedges.** Client is sending, server stops reading, OS receive buffer fills, writes go unacked → kernel kills.
- **Network partitions.** Peer unreachable → unacked retransmits → kernel kills.

## What this does NOT cover

- **Read-side wedges where the peer is responsive at the kernel level.** If the peer's userspace is stuck but its kernel auto-ACKs your packets, `TCP_USER_TIMEOUT` does not fire. Use application-level timeouts for these (`Net::HTTP#read_timeout`, `IO#timeout=`, SDK request timeouts).
- **Pre-existing sockets.** Hooks fire on socket *creation*. Connections in the DB pool or a persistent HTTP pool that were opened at boot are not re-bound. This is by design — production pools that should outlive any single request keep their original behavior.
- **FFI / libcurl-based clients.** curb, anything wrapping libcurl — bypasses Ruby's socket layer entirely.
- **DNS.** `getaddrinfo` is not covered. Mitigate via `resolv.conf`.
- **Connect phase.** Use `Net::HTTP#open_timeout`, libpq `connect_timeout`, etc.

## Platform support

- **Linux**: enforced by the kernel.
- **macOS / BSD / Windows**: silent no-op. There is no direct equivalent of `TCP_USER_TIMEOUT`; `setsockopt` raises `Errno::ENOPROTOOPT` and the gem rescues it. Dev work and tests on macOS run unaffected; production should be Linux.

## Installation

```ruby
gem "tcp_user_timeout"
```

## Usage

### Direct

```ruby
TcpUserTimeout.with_timeout(30) do
  Net::HTTP.get(URI("..."))
end
```

Nests; restores outer scope on exception. Storage uses `Fiber[]` (Ruby 3.2+ inheritable fiber storage), so child fibers and threads spawned inside the block see the same deadline.

### Rack middleware

Bound every newly-opened TCP socket during a request to slightly less than the web server's worker timeout (Puma's `worker_timeout`, Heroku's 30s router cap, etc.):

```ruby
# config/application.rb
require "tcp_user_timeout/rack"
config.middleware.use TcpUserTimeout::Rack::Middleware, seconds: 25
```

Per-request override via callable:

```ruby
config.middleware.use TcpUserTimeout::Rack::Middleware,
  seconds: ->(env) { env["HTTP_X_REQUEST_TIMEOUT_S"]&.to_f || 25 }
```

Pre-existing pooled connections (the AR pool, persistent HTTP pools created at boot) are not touched — the middleware only affects sockets *opened during* the request.

### ActiveJob

```ruby
require "tcp_user_timeout/active_job"

class FetchUpstreamJob < ApplicationJob
  include TcpUserTimeout::ActiveJob
  self.max_execution_time = 30.seconds

  def perform(url)
    Net::HTTP.get(URI(url))
  end
end
```

`max_execution_time` becomes a real upper bound on outbound TCP work. The actual TCP deadline is set slightly below — 5s headroom at production scales (≥10s), 90% of max below that — so the kernel fires *before* any outer guard.

### Global default

Set a ceiling that applies when no `with_timeout` block is in effect:

```ruby
TcpUserTimeout.global_default_seconds = 600  # 10 min safety net
```

Default is `nil` (no global ceiling).

## Development

```bash
bundle install
bundle exec rake test           # macOS-friendly; Linux-only tests skip
docker build -f Dockerfile.test -t tcp-user-timeout-test:linux .
docker volume create tcp-user-timeout-bundle
docker run --rm -v $PWD:/app -v tcp-user-timeout-bundle:/bundle \
  tcp-user-timeout-test:linux bundle install
docker run --rm -v $PWD:/app -v tcp-user-timeout-bundle:/bundle \
  tcp-user-timeout-test:linux bundle exec rake test
```

## References

- [`tcp(7)` — TCP_USER_TIMEOUT](https://man7.org/linux/man-pages/man7/tcp.7.html)
- [Cloudflare: When TCP sockets refuse to die](https://blog.cloudflare.com/when-tcp-sockets-refuse-to-die/)
- [gRPC proposal A18-tcp-user-timeout](https://github.com/grpc/proposal/blob/master/A18-tcp-user-timeout.md)

## License

MIT.

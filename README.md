# tcp_user_timeout

**Kernel-enforced TCP timeouts for Ruby.** Threads that wedge in network syscalls die at the deadline you set — at the kernel level, not at the Ruby level.

> Verified on Ruby 3.3 / Linux. Full suite: **49 unit + safety + integration tests, 4 kernel-enforcement tests, 0 failures.** The kernel suite forces a wedged TCP write against a non-reading server and proves the deadline fires within ~1.5s of the configured 1s. See `test/linux/kernel_enforcement_test.rb`.

```ruby
TcpUserTimeout.with_timeout(30) do
  Net::HTTP.get(URI("https://example.com"))
end
# If the server stops making forward progress, the Linux kernel kills the
# connection at ~30 seconds and Ruby raises Errno::ETIMEDOUT.
```

## The wedge that motivated this gem

A Ruby worker process sat at 100% memory and 0% CPU for 45 minutes. SolidQueue's reaper logged "claimed_executions: 12" and refused to release them. `kill -QUIT` produced no thread dump. The supervisor eventually OOM-killed the worker. Twelve user-visible jobs lost in flight.

Root cause: an upstream API stopped reading from its TCP socket. The Ruby `write` call blocked in `sendmsg(2)` waiting for an ACK that never came. The job's outer `Timeout.timeout(60)` did exactly nothing — `Timeout.timeout` works by raising in the calling thread when control returns to user space, and the calling thread had not returned to user space. It was parked in the kernel.

This is not a Ruby bug, a SolidQueue bug, or a Net::HTTP bug. It's the well-documented limit of MRI's threading model: **a thread blocked in a syscall cannot be interrupted from Ruby**. `Thread#kill`, `Thread#raise`, and `Timeout.timeout` all set flags that the blocked thread will check the next time it returns from the kernel. If it never returns, the flag is never read.

The fix has to live in the kernel itself. Linux's [`TCP_USER_TIMEOUT`](https://man7.org/linux/man-pages/man7/tcp.7.html) socket option tells the kernel: *if data sent on this connection goes unacknowledged for N milliseconds, forcibly close the connection and return ETIMEDOUT to userspace.* The kernel drops the connection. The blocking syscall returns. The Ruby thread unblocks. Your `rescue Errno::ETIMEDOUT` runs. The worker recovers.

This gem makes `TCP_USER_TIMEOUT` easy to apply — globally, per-block, per-request, per-job — without you having to remember the optname, the level constant, or the platform fallback.

## Why this works when `Timeout.timeout` does not

| Mechanism | How it cancels | Wedged-syscall outcome |
|-----------|----------------|------------------------|
| `Timeout.timeout(N) { ... }` | Background thread raises in target thread when it returns to user space | **Hangs forever.** The target thread is in the kernel and never checks the flag. |
| `Thread#kill` / `Thread#raise` | Same flag-based interrupt mechanism | **Hangs forever.** Same reason. |
| TCP keepalive | Kernel probes idle connections; closes after ~2 hours of inactivity | "Works" eventually. Production-unusable. |
| `SO_RCVTIMEO` / `SO_SNDTIMEO` | Per-socket recv/send timeout | Works — but only covers reads/writes, not the actual wedge condition (data sent, no ACK). |
| **`TCP_USER_TIMEOUT`** | **Kernel forcibly closes the socket when transmitted data goes unacknowledged for N ms** | **Works.** The syscall returns with ETIMEDOUT. Ruby unblocks. |

`TCP_USER_TIMEOUT` is the only mechanism that addresses the actual failure mode (forward progress stops at the network layer) at the layer where the thread is actually stuck (the kernel).

## Before / after

Run on Linux (or via the included `Dockerfile.test` from macOS):

```text
$ ruby examples/before_after.rb before
server listening on 127.0.0.1:54321
[hangs indefinitely; ctrl-C after 60s]

$ ruby examples/before_after.rb after
server listening on 127.0.0.1:54321
got IO::TimeoutError: Blocking operation timed out! after 1.0s
```

## Status

Pre-1.0. The core mechanism is small (one `setsockopt` call + thread-local state + a `Module#prepend`) and verified end-to-end on Linux. The Rack middleware and ActiveJob concern have unit tests. The Sidekiq middleware is unit-tested with synthesized job hashes; running it inside a real Sidekiq server has not yet been validated by this maintainer. The integrations are thin glue around the same `with_timeout` block — if one of them misbehaves for you, calling `with_timeout` directly inside your job's `perform` is the always-works escape hatch.

## What this gem does NOT do

To set expectations clearly:

- **It does not interrupt CPU-bound or non-network code.** A pure-Ruby infinite loop is unaffected. This gem only addresses *socket-level* wedges.
- **It does not cover DNS resolution.** `getaddrinfo(3)` happens before the TCP socket exists. A wedged resolver bypasses `TCP_USER_TIMEOUT` entirely. Configure `resolv.conf` (`options timeout:1 attempts:2`) or use a DNS client with its own timeout.
- **It does not cover the TCP connect phase.** `TCP_USER_TIMEOUT` only applies once the socket is established. Use the host library's connect-timeout (`Net::HTTP#open_timeout`, libpq `connect_timeout`, etc.) for that phase.
- **It does not cover FFI-based clients.** libcurl (curb), C-level MySQL clients, libsodium, etc., open their own sockets at the C layer and bypass Ruby's `TCPSocket`. Pure-Ruby HTTP clients (`Net::HTTP`, `httpx`, most Faraday adapters, `excon`) are covered.
- **It does not retry.** When the kernel kills the connection, your code receives `Errno::ETIMEDOUT` (or one of the related exception classes — see [Catching the timeout](#catching-the-timeout-in-your-rescue-blocks)). Retry policy is yours.
- **It does not work on macOS, BSD, or Windows.** No equivalent socket option exists. The gem silently no-ops on those platforms so dev workflows are unaffected, but production must run on Linux for the deadline to actually fire.

## Production Linux Rails coverage

Out-of-the-box coverage for a typical Rails-on-Linux production stack:

| Layer | Tool | Mechanism |
|-------|------|-----------|
| Web server | Puma, Falcon, Passenger, Thin, Unicorn | Rack middleware bounds the request |
| Job queue | Sidekiq | Server middleware (this gem) |
| Job queue | SolidQueue | `require "tcp_user_timeout/solid_queue"` |
| Job queue | GoodJob | ActiveJob concern |
| Job queue | Resque, DelayedJob | Wrap `perform` with `with_timeout` |
| HTTP client | `Net::HTTP`, `httpx`, Faraday (Net::HTTP/httpx adapters), Excon, RestClient | Socket-layer hook |
| HTTP client | `curb` (libcurl) | **Not covered** — use libcurl's own timeouts |
| Database | PostgreSQL via libpq | Native `tcp_user_timeout` connection param |
| Database | MySQL via Trilogy (Rails 7.1+) | Socket-layer hook |
| Database | MySQL via mysql2 | **Not covered** — use adapter `read_timeout` |
| Database | MongoDB Ruby driver | Socket-layer hook |
| Cache / store | Redis (`redis-rb`), Memcached (`dalli`) | Socket-layer hook |
| Email | `Net::SMTP`, `Mail`, ActionMailer | Socket-layer hook |
| RPC | gRPC (`grpc` gem) | **Not covered** — use gRPC `deadline:` |
| WebSockets / SSE / pub/sub | Action Cable, Redis pub/sub | Use `exempt_hosts` to skip |

If your stack is in the "Not covered" rows, either use that layer's own timeout primitive or rely on `global_default_seconds` as a coarse safety net for everything else.

## Compatibility

| Requirement | Version |
|-------------|---------|
| Ruby | 3.2+ (uses `Fiber[]` inheritable storage so child threads/fibers spawned inside `with_timeout` get the deadline) |
| Linux kernel | 2.6.37+ (TCP_USER_TIMEOUT was added in 2010) |
| Rails | 7.0+ (optional — only needed for the Railtie and ActiveJob concern) |
| Sidekiq | any version with server-middleware support (optional) |
| SolidQueue | any version (optional — uses ActiveJob middleware) |

macOS, BSD, and Windows are supported as **silent no-ops** so dev workflows are unaffected. Kernel-level enforcement requires Linux.

## Install

```ruby
# Gemfile
gem "tcp_user_timeout"
```

For non-Rails apps, install the Socket hooks once at app boot:

```ruby
require "tcp_user_timeout"
TcpUserTimeout.install!
```

For Rails apps, the included Railtie handles install at boot. No initializer required unless you want to set a global ceiling:

```ruby
# config/initializers/tcp_user_timeout.rb
TcpUserTimeout.global_default_seconds = 600  # 10 minute safety net
```

### Recommended Rails setup

A complete production initializer covering all three tiers:

```ruby
# config/initializers/tcp_user_timeout.rb

# Global ceiling: every outbound TCP socket gets at most 10 minutes.
# This is your "no thread wedges forever" insurance policy.
TcpUserTimeout.global_default_seconds = 600

# Connections that legitimately stay idle for long periods.
# (Action Cable, Server-Sent Events, Redis pub/sub, message-broker subscribers.)
TcpUserTimeout.exempt_hosts = [
  /\.internal\z/,         # service mesh (managed elsewhere)
  /actioncable/,          # WebSocket endpoints
  /redis-pubsub/          # subscriber connections
]
```

```ruby
# config/application.rb

# Web tier: bound every request below Puma's worker_timeout.
config.middleware.use TcpUserTimeout::Middleware, timeout: 30
```

```ruby
# app/jobs/application_job.rb

class ApplicationJob < ActiveJob::Base
  include ActiveJob::MaxExecutionTime
end
```

```ruby
# Any job:

class FetchUpstreamJob < ApplicationJob
  self.max_execution_time = 30.seconds

  def perform(url)
    Net::HTTP.get(URI(url))
  end
end
```

That's it. The web request, the job, and any specific call inside either of them are all bounded by the kernel.

## Block API

Scope a deadline to a specific operation:

```ruby
TcpUserTimeout.with_timeout(30) do
  result = AnthropicClient.create_message(...)
end
# Inside the block, every newly opened TCP socket gets TCP_USER_TIMEOUT = 30s.
# Outside the block, the previous setting (or the global default) applies.
```

`with_timeout` is thread-local and exception-safe. It nests cleanly:

```ruby
TcpUserTimeout.with_timeout(60) do  # outer bound: 60s
  TcpUserTimeout.with_timeout(5) do # tighter inner: 5s
    risky_call
  end
  # back to 60s here
end
```

## Rack middleware

Bound every web request:

```ruby
# config/application.rb
config.middleware.use TcpUserTimeout::Middleware, timeout: 30
```

Works with any Rack server: **Puma, Falcon, Passenger, Thin, Unicorn**. Set the timeout below your web server's request kill threshold (Puma's `worker_timeout`, Falcon's deadline, Passenger's `max_request_time`, NGINX's `proxy_read_timeout`) so the kernel-level kill happens before the supervisor takes the worker down. A common shape:

| Layer                              | Bound        |
|------------------------------------|--------------|
| NGINX `proxy_read_timeout`         | 60s          |
| Puma `worker_timeout` (or Passenger `max_request_time`) | 60s |
| `TcpUserTimeout::Middleware`       | 30s          |
| Per-call `TcpUserTimeout.with_timeout` | 5–15s    |

Skip the bound for specific requests:

```ruby
class StreamingController < ApplicationController
  before_action { request.env["tcp_user_timeout.skip"] = true }
end
```

## ActiveJob — `max_execution_time` as an enforced contract

Most queue libraries treat job timeouts as observability — fire an alert if the job runs too long, but don't actually bound anything. `TcpUserTimeout` makes the contract real:

```ruby
class FetchUpstreamJob < ApplicationJob
  include ActiveJob::MaxExecutionTime
  self.max_execution_time = 30.seconds

  def perform(url)
    Net::HTTP.get(URI(url))
  end
end
```

If the upstream wedges, the kernel closes the socket at ~25s (5s headroom for the rescue handler) and the job fails cleanly instead of leaking the worker thread until the process restarts.

To apply this to every job:

```ruby
class ApplicationJob < ActiveJob::Base
  include ActiveJob::MaxExecutionTime
end
```

## SolidQueue integration

If you're on SolidQueue, one require wires everything up:

```ruby
# config/initializers/tcp_user_timeout.rb
require "tcp_user_timeout/solid_queue"
```

This installs the Socket hooks and includes `ActiveJob::MaxExecutionTime` into `ActiveJob::Base`, so any job that declares `self.max_execution_time = N.seconds` gets enforced bounds without further changes.

## Sidekiq integration

Sidekiq doesn't go through ActiveJob by default, so the binding mechanism is a server middleware that reads `max_execution_time` from `sidekiq_options`:

```ruby
# config/initializers/sidekiq.rb
require "tcp_user_timeout/sidekiq"

class FetchUpstreamWorker
  include Sidekiq::Worker
  sidekiq_options max_execution_time: 30

  def perform(url)
    Net::HTTP.get(URI(url))
  end
end
```

If you also use ActiveJob on top of Sidekiq, additionally include `ActiveJob::MaxExecutionTime` into `ApplicationJob` — both layers compose (innermost `with_timeout` wins).

## GoodJob, Resque, and other queues

Same pattern as Sidekiq — wrap each job's `perform` in `TcpUserTimeout.with_timeout(seconds)`. For GoodJob (which uses ActiveJob), `ActiveJob::MaxExecutionTime` is enough; just install the hooks at boot:

```ruby
# config/initializers/tcp_user_timeout.rb
require "tcp_user_timeout"
TcpUserTimeout.install!

ActiveSupport.on_load :active_job do
  include ActiveJob::MaxExecutionTime
end
```

For Resque (or any queue with a worker-class hook), wrap `perform` directly:

```ruby
class FetchUpstreamWorker
  MAX_EXECUTION_TIME = 30

  def self.perform(*args)
    TcpUserTimeout.with_timeout(MAX_EXECUTION_TIME) do
      new.do_work(*args)
    end
  end
end
```

The general principle: any queue with a "run this code" extension point can wrap that point in `with_timeout`. The Sidekiq middleware and ActiveJob concern in this gem are convenience wrappers around exactly this pattern.

## Per-host exempt list

Some connections legitimately stay idle for long periods and should not be torn down by the kernel. Configure exempt hosts to skip those:

```ruby
TcpUserTimeout.exempt_hosts = [
  /\.internal\z/,         # internal mesh — managed elsewhere
  "kafka-broker-1",       # specific broker
  /redis-pubsub/,         # subscriber connections
  /actioncable/           # WebSocket / SSE endpoints
]
```

Strings match exactly. Regexps match via `=~`. The exempt list applies to any socket opened with a known host (i.e., everything that goes through `Socket.tcp` / `TCPSocket.new` — which is almost everything pure-Ruby).

## Where you don't want this

`TCP_USER_TIMEOUT` forces the kernel to kill connections that haven't made forward progress within the deadline. That's wrong for:

- **WebSockets and Action Cable.** Idle gaps between messages are normal. Add the host to `exempt_hosts`, or set the per-block timeout to something larger than the maximum expected idle period. For Action Cable specifically:

  ```ruby
  # config/initializers/tcp_user_timeout.rb
  TcpUserTimeout.exempt_hosts = [
    /actioncable/,                    # Action Cable mount point
    /\.cable\./                       # any host containing ".cable."
  ]
  ```

- **Server-Sent Events (SSE).** Same as WebSockets — long-lived idle stream.
- **Message broker subscribers** (Kafka consumer connections, Redis pub/sub subscribers). The connection is supposed to sit there waiting for messages. Either exempt the host, or set the timeout to something well above your producer's max-idle.
- **Long-poll endpoints.** `/poll?wait=300` etc. — exempt the host or scope the timeout to be larger than your poll deadline.
- **Pooled connections you don't control.** See the persistent-pool note in [Failure modes](#failure-modes-worth-knowing) below.

## Deployment pattern: layered timeouts

Production-quality timeout configs operate at three tiers, each tightening as you get closer to the actual call:

| Tier | Mechanism | Typical bound |
|------|-----------|---------------|
| Outer (transport) | Web server / queue supervisor | 60s |
| Middle (request/job scope) | `TcpUserTimeout::Middleware` / `max_execution_time` | 30s |
| Inner (per call) | `TcpUserTimeout.with_timeout(N)` around specific calls | 5–15s |

Inner bounds are tighter than outer bounds so the inner failure raises a recoverable exception (your `rescue` runs, the request returns 504, the job retries) before the outer supervisor pulls the plug on the whole worker.

## Headroom math

The TCP_USER_TIMEOUT we set is slightly less than the declared deadline so the kernel kills the socket *before* any outer guard fires:

| `max_execution_time` | `TCP_USER_TIMEOUT` |
|---------------------|--------------------|
| 1s                  | 0.9s               |
| 10s                 | 5s                 |
| 30s                 | 25s                |
| 90s                 | 85s                |
| 10min               | 9min 55s           |

5s headroom at production scales (≥10s); 90% of max below that so very short timeouts in tests still get enforced. Implementation: `ActiveJob::MaxExecutionTime.headroom_seconds`.

## Concurrency safety

The block API is safe under MRI's threading, fiber, and fork models. State is held in `Fiber[]` (Ruby 3.2+ inheritable fiber storage) with a `Thread.current[]` fallback for older Rubies.

- **Threads spawned inside `with_timeout` inherit the deadline.** If a job spawns helper threads to do parallel I/O, those threads are bounded by the same kernel deadline as the job itself. (This is what you want — the alternative leaves sub-thread I/O unbounded.)
- **Fibers spawned inside `with_timeout` inherit the deadline.** Falcon, Async, and any fiber-per-task pattern get the deadline propagated to spawned subtasks.
- **Threads/fibers spawned outside `with_timeout` never see it.** No global leakage.
- **Concurrent `with_timeout` calls on different top-level threads are isolated.** Each thread's main fiber has its own storage slot.
- **Fork.** `install!` is idempotent and survives `fork(2)` — the child inherits the prepended hooks, and a second `install!` in the child does not double-prepend.
- **Concurrent `install!`.** Calling `install!` from multiple threads at boot is safe; the prepend will not happen more than once.
- **Pre-existing sockets are never rebound.** Hooks fire on socket *creation*, not on every operation. Boot-time pool connections (ActiveRecord, persistent HTTP pools, Redis) keep their original behavior — only new sockets opened *inside* a `with_timeout` block get bound. This is the property that makes the gem safe to drop into a Rails app with long-lived pools.

`global_default_seconds` and `exempt_hosts` are unsynchronized class-level state and should be set once at boot, before threads are accepting work. Both are immutable in steady state, so there is no read/write contention concern after boot.

## Catching the timeout in your rescue blocks

When `TCP_USER_TIMEOUT` fires, the exception class your code sees depends on which Ruby IO layer was on top of the socket. Production rescues should catch all four:

```ruby
require "net/http"
require "openssl"

begin
  TcpUserTimeout.with_timeout(30) do
    Net::HTTP.get(URI("https://upstream.example.com"))
  end
rescue Errno::ETIMEDOUT,         # raw read/write surface
       IO::TimeoutError,          # Ruby 3.2+ wrapper for some IO operations
       Net::ReadTimeout,          # Net::HTTP's wrapping of either of the above
       OpenSSL::SSL::SSLError     # TLS connections may surface socket death as a TLS error
       => e
  Rails.logger.warn("upstream wedged: #{e.class}: #{e.message}")
  # Retry, return a stale cache, surface a 504, etc.
end
```

`OpenSSL::SSL::SSLError` is included because OpenSSL on top of TCP can wrap the underlying socket's `ETIMEDOUT` as a TLS error rather than passing it through cleanly. Both behaviors are "valid" kernel-enforced timeouts; you just need to catch both classes.

## Failure modes worth knowing

This gem is a sharp tool. Read these before relying on it.

- **Exception class translation.** When the kernel kills the connection, Ruby surfaces it as either `Errno::ETIMEDOUT` (lower-level reads/writes) or `IO::TimeoutError` (Ruby 3.2+'s wrapping of certain IO operations). `Net::HTTP` may further wrap as `Net::ReadTimeout`. Production rescues should catch all three, plus `OpenSSL::SSL::SSLError` for TLS-wrapped sockets where the SSL layer surfaces the underlying socket death as a TLS error.

- **TLS-wrapped sockets.** OpenSSL on top of TCP — when the kernel kills the underlying socket mid-`SSL_read`, the SSL layer can surface a clean `Errno::ETIMEDOUT` or an `OpenSSL::SSL::SSLError`. Both are valid kernel-enforced timeouts; rescues should catch both classes.

- **Persistent connection pools.** Pooled connections retain the `TCP_USER_TIMEOUT` value from whichever request created them. Per-block tightening is best-effort for pooled connections; `global_default_seconds` is the operative ceiling. See the [pooled-client section](#persistent-connection-pools) for client-specific guidance.

- **DNS not covered.** `TCP_USER_TIMEOUT` only applies after the TCP socket is established. `getaddrinfo` wedges (slow/wedged resolver) bypass this entirely. Mitigate via `resolv.conf` (`options timeout:1 attempts:2`) or via your platform's DNS settings.

- **Connect timeout vs read timeout.** `TCP_USER_TIMEOUT` covers post-connection wedges. The connect phase has its own timeout — `Net::HTTP#open_timeout`, libpq `connect_timeout`, etc. Both layers needed.

- **FFI-based clients bypass the hooks.** This gem prepends `Socket.tcp`, `TCPSocket.new`, and `TCPSocket.open`. Anything wrapping libcurl (curb), or other FFI-based HTTP clients, bypasses Ruby's socket layer and isn't covered. Pure-Ruby HTTP clients (`Net::HTTP`, `httpx`, most Faraday adapters, `excon`) all go through the hooked methods.

- **Linux only.** macOS, BSD, and Windows don't support `TCP_USER_TIMEOUT`. The gem silently no-ops via `Errno::ENOPROTOOPT` on those platforms, which keeps dev work unaffected but also means you can't validate kernel enforcement locally on a Mac. Use the included `Dockerfile.test` to run the kernel tests against Linux from anywhere.

## Database and pooled-client integrations

This gem hooks Ruby's socket layer, which means it covers any pure-Ruby client (`Net::HTTP`, `httpx`, most Faraday adapters, `redis-rb`, `excon`, `mongo` ruby driver). It does **not** cover clients whose sockets are managed at the C level (libpq, libmysqlclient, libcurl). For those, the underlying library typically exposes its own equivalent of `TCP_USER_TIMEOUT` — set it there, and let this gem cover everything else.

### PostgreSQL (libpq)

libpq supports `tcp_user_timeout` as a connection parameter directly (PG 12+). For Postgres connections specifically, set it server-side without going through this gem's Ruby socket hooks:

```yaml
# config/database.yml
default: &default
  adapter: postgresql
  connect_timeout: 5
  variables:
    statement_timeout: '120s'
  tcp_user_timeout: 600000  # ms; 10 min safety net for non-job DB calls
```

### MySQL (libmysqlclient)

The C client doesn't expose `TCP_USER_TIMEOUT` directly, but Trilogy (Ruby 3.0+, the new default for Rails 7.1+) goes through Ruby sockets and *is* covered by this gem. If you're still on the legacy `mysql2` adapter, rely on `read_timeout` / `write_timeout` at the adapter level — they don't kill wedged connections at the kernel layer, but they do bound TCP-active reads.

### MongoDB

The Ruby driver opens sockets via `TCPSocket.new`, so this gem covers them. The driver also exposes `socket_timeout` / `connect_timeout` as connection options — set both for belt-and-suspenders.

### Redis

`redis-rb` uses Ruby sockets — covered. Set `connect_timeout`, `read_timeout`, `write_timeout` at client construction as a separate layer. Note that pub/sub subscribers (`subscribe`, `psubscribe`) hold connections idle for arbitrary durations — add those hosts to `exempt_hosts`.

### Memcached (dalli)

`dalli` opens TCP sockets via `TCPSocket.new` for non-Unix-socket connections — covered by the gem's hooks. The dalli client also supports `socket_timeout:` at construction (default 0.5s); both layers compose. Memcached connections are typically short and fast, so the kernel deadline rarely fires in practice but is there as the safety net.

### SMTP (Net::SMTP / Mail / ActionMailer)

`Net::SMTP` opens sockets via `TCPSocket.open` — covered. `Mail`'s SMTP delivery method goes through `Net::SMTP`, and `ActionMailer` uses `Mail` underneath, so the entire mail-delivery stack is covered. SMTP servers can stop responding mid-transaction (relay troubles, greylisting); the deadline catches that.

### gRPC (FFI-based)

The official `grpc` gem links libgrpc at the C level — its sockets are NOT visible to this gem's hooks. gRPC has its own deadline/timeout API (`deadline:` on every call); use it. The `grpc` proposal A18 documents kernel-level `TCP_USER_TIMEOUT` for gRPC at the C layer, but you have to enable it via channel args.

### Persistent connection pools

Pooled clients (ActiveRecord, `redis-rb` with a connection pool, custom HTTP keep-alive pools) retain whatever `TCP_USER_TIMEOUT` was set when the connection was created. `with_timeout` only affects sockets opened *inside* the block — pooled connections opened earlier keep their original setting.

In practice this means:

- `global_default_seconds` is the operative ceiling for all pooled connections.
- `with_timeout` is best-effort for pooled clients — if the pool already has a warm connection, it'll be used as-is.
- For tighter per-call bounds against a pooling client, either force a fresh connection, or live with the pool's existing bound and rely on application-level retries.

## Testing

The cross-platform unit tests run anywhere:

```sh
bundle exec rake test
```

The Linux-only kernel enforcement tests need a Linux box. Use the bundled Docker image from a macOS dev machine:

```sh
docker build -f Dockerfile.test -t tcp_user_timeout:linux .
docker run --rm -v $PWD:/app -w /app tcp_user_timeout:linux \
  bash -c "bundle install && bundle exec rake test:linux"
```

Expected: `0 failures, 0 errors` on Linux.

## Sources

- [`tcp(7)` man page](https://man7.org/linux/man-pages/man7/tcp.7.html) — canonical Linux reference
- [Cloudflare: When TCP sockets refuse to die](https://blog.cloudflare.com/when-tcp-sockets-refuse-to-die/) — definitive blog on the underlying problem
- [Instacart: The Vanishing Thread and PostgreSQL TCP Connection Parameters](https://tech.instacart.com/the-vanishing-thread-and-postgresql-tcp-connection-parameters-93afc0e1208c) — production war story
- [gRPC proposal A18-tcp-user-timeout](https://github.com/grpc/proposal/blob/master/A18-tcp-user-timeout.md) — design rationale
- [Linux kernel commit](https://github.com/torvalds/linux/commit/dca43c75e7e545694a9dd6288553f55c53e2a3a3)
- [Ankane: The Ultimate Guide to Ruby Timeouts](https://github.com/ankane/the-ultimate-guide-to-ruby-timeouts) — reference for how various Ruby gems surface timeout exceptions

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

## License

MIT. See [LICENSE](LICENSE).

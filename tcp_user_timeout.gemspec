# frozen_string_literal: true

require_relative "lib/tcp_user_timeout/version"

Gem::Specification.new do |spec|
  spec.name        = "tcp_user_timeout"
  spec.version     = TcpUserTimeout::VERSION
  spec.authors     = ["Brad Gessler"]
  spec.email       = ["brad@rocketship.io"]

  spec.summary     = "Kernel-enforced TCP timeouts for Ruby. Threads that wedge in network syscalls die at the deadline you set."
  spec.description = <<~DESC.strip
    Sets TCP_USER_TIMEOUT on outbound TCP sockets so the Linux kernel forcibly
    closes connections that have stopped making forward progress. The kernel —
    not Ruby, not Timeout.timeout, not a watchdog — drops the connection at the
    deadline and returns ETIMEDOUT, freeing whatever Ruby thread was parked in
    the blocking syscall. Includes optional Rack middleware for bounding web
    requests and an ActiveJob concern for bounding background jobs.
  DESC
  spec.homepage    = "https://github.com/rubymonolith/tcp_user_timeout"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "sig/**/*.rbs",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "tcp_user_timeout.gemspec"
  ]
  spec.require_paths = ["lib"]

  # All optional. The core gem has zero runtime dependencies — it only uses
  # Ruby's stdlib `socket`. The Railtie, middleware, and SolidQueue
  # integration require their respective hosts but only at load time, and
  # only when you require the relevant entrypoints.
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rack", ">= 2.0"
  spec.add_development_dependency "rack-test", ">= 2.0"
  spec.add_development_dependency "activejob", ">= 7.0"
  spec.add_development_dependency "activesupport", ">= 7.0"
end

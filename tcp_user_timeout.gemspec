# frozen_string_literal: true

require_relative "lib/tcp_user_timeout/version"

Gem::Specification.new do |spec|
  spec.name = "tcp_user_timeout"
  spec.version = TcpUserTimeout::VERSION
  spec.authors = ["Brad Gessler"]
  spec.email = ["bradgessler@gmail.com"]

  spec.summary = "Kernel-enforced socket deadlines via Linux TCP_USER_TIMEOUT."
  spec.description = <<~DESC
    Wraps the Linux TCP_USER_TIMEOUT (and optional SO_KEEPALIVE) socket
    options behind a fiber-safe block API. Sockets opened inside the block
    inherit a deadline the kernel itself enforces — Ruby threads parked in
    blocking syscalls that Thread#kill and Timeout.timeout cannot interrupt
    are released when the kernel drops the connection. No-op on macOS and
    other non-Linux platforms.
  DESC
  spec.homepage = "https://github.com/rubymonolith/tcp_user_timeout"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end

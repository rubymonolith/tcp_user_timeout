# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/linux/**/*_test.rb")
  t.verbose = true
end

# Linux-only kernel enforcement tests. These exercise TCP_USER_TIMEOUT
# behavior against a real local TCP server, which only works on Linux —
# macOS / BSD silently no-op the option. Run via Docker on dev machines.
Rake::TestTask.new("test:linux") do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/linux/**/*_test.rb"]
  t.verbose = true
end

task default: :test

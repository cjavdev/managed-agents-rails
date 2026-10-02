require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"
require "rake/testtask"

begin
  require "standard/rake"
rescue LoadError
  # The per-Rails gemfiles used in CI don't include the linter.
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.verbose = false
end

task default: Rake::Task.task_defined?(:standard) ? [:test, :standard] : [:test]

ENV["RAILS_ENV"] = "test"
# Tests start subprocesses in other directories; a relative path would break there.
ENV["BUNDLE_GEMFILE"] = File.expand_path(ENV["BUNDLE_GEMFILE"]) if ENV["BUNDLE_GEMFILE"]

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
# The dummy app has no schema.rb, so the same migrations run on every
# supported Rails version.
ActiveRecord::Schema.verbose = false
ActiveRecord::Base.connection_pool.migration_context.migrate
require "rails/test_help"
require "webmock/minitest"
require "managed_agents/testing"

WebMock.disable_net_connect!

class ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ManagedAgents::Testing::Helper

  setup do
    @original_config = ManagedAgents.config.dup
    ManagedAgents.config.reconnect_delay = 0
    ENV["HELPDESK_MCP_TOKEN"] = "token-one"
  end

  teardown do
    ManagedAgents.instance_variable_set(:@config, @original_config)
    ENV.delete("HELPDESK_MCP_TOKEN")
    FileUtils.rm_rf(Rails.root.join("tmp/test_agents"))
    FileUtils.rm_rf(Rails.root.join("tmp/managed_agents"))
  end

  # Points the engine at a throwaway agents folder. Keys are paths relative to
  # that folder.
  def with_agents(files)
    root = Rails.root.join("tmp/test_agents", SecureRandom.hex(4))
    files.each do |path, content|
      target = root.join(path)
      FileUtils.mkdir_p(target.dirname)
      File.write(target, content)
    end
    ManagedAgents.config.agents_path = root.relative_path_from(Rails.root).to_s
    root
  end

  def agent_files(name = "helper", agent: nil, environment: nil)
    {
      "#{name}/agent.md" => agent || "---\nname: #{name.humanize}\nmodel: claude-opus-5-5\n---\n\nYou help.\n",
      "#{name}/environment.yaml" => environment || "name: #{name}-env\nconfig:\n  type: cloud\n"
    }
  end

  # Replaces a singleton method for the duration of the block.
  def stub_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name) { |*args, **options, &block| replacement.call(*args, **options, &block) }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def sync(**)
    output = StringIO.new
    changes = ManagedAgents::Sync.new(backend: :api, io: output, **).apply
    [changes, output.string]
  end

  def resource(agent_name, kind, key = "")
    ManagedAgents::Resource.lookup(agent_name, kind, key)
  end
end

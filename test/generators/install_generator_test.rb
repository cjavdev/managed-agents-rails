require "test_helper"
require "generators/managed_agents/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests ManagedAgents::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  setup do
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  test "creates the initializer, migration and ApplicationAgent, and mounts the engine" do
    run_generator

    assert_file "config/initializers/managed_agents.rb", /ManagedAgents.configure do \|config\|/
    assert_file "app/agents/application_agent.rb", /class ApplicationAgent < ManagedAgents::Agent/
    assert_file "config/routes.rb", %r{mount ManagedAgents::Engine => "/managed_agents"}
    assert_migration "db/migrate/create_managed_agents_tables.rb" do |migration|
      assert_match "ActiveRecord::Migration[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]", migration
      assert_match "create_table :managed_agents_resources do", migration
      assert_match "create_table :managed_agents_sessions do", migration
      assert_match "create_table :managed_agents_events do", migration
      assert_match "t.index [:agent_name, :kind, :key], unique: true", migration
    end
  end

  test "follows the app's primary key type" do
    options = Rails.configuration.generators.options
    original = options[:active_record]&.dup
    (options[:active_record] ||= {})[:primary_key_type] = :uuid

    run_generator

    assert_migration "db/migrate/create_managed_agents_tables.rb" do |migration|
      assert_match "create_table :managed_agents_sessions, id: :uuid do", migration
      assert_match "t.references :subject, polymorphic: true, type: :uuid", migration
      assert_match "foreign_key: {to_table: :managed_agents_sessions}, type: :uuid", migration
    end
  ensure
    options[:active_record] = original
  end

  test "the migration in the dummy app matches the template" do
    run_generator
    generated = Dir[File.join(destination_root, "db/migrate/*_create_managed_agents_tables.rb")].sole
    dummy = Dir[Rails.root.join("db/migrate/*_create_managed_agents_tables.rb")].sole

    version = /ActiveRecord::Migration\[.+\]$/
    assert_equal File.read(generated).sub(version, ""), File.read(dummy).sub(version, "")
  end
end

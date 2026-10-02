require "rails/generators"
require "rails/generators/active_record"

module ManagedAgents
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Sets up managed_agents: initializer, migration, ApplicationAgent and the engine mount."

      def create_initializer
        template "initializer.rb", "config/initializers/managed_agents.rb"
      end

      def copy_migration
        migration_template "migration.rb", "db/migrate/create_managed_agents_tables.rb"
      end

      def create_application_agent
        template "application_agent.rb", "app/agents/application_agent.rb"
      end

      def mount_engine
        route 'mount ManagedAgents::Engine => "/managed_agents"'
      end

      def show_readme
        readme "README" if behavior == :invoke
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def key_type
        Rails.configuration.generators.options.dig(:active_record, :primary_key_type)
      end

      def primary_key_type
        ", id: :#{key_type}" if key_type
      end

      def foreign_key_type
        ", type: :#{key_type}" if key_type
      end

      def json_type
        ActiveRecord::Base.connection_db_config.adapter.to_s.match?(/postg/i) ? "jsonb" : "json"
      rescue ActiveRecord::ActiveRecordError
        "json"
      end
    end
  end
end

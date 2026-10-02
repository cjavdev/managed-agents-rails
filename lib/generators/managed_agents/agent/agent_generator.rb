require "rails/generators"

module ManagedAgents
  module Generators
    class AgentGenerator < Rails::Generators::NamedBase
      SCHEDULES = {
        /hour/ => "0 * * * *",
        /week/ => "0 9 * * 1",
        /month/ => "0 9 1 * *",
        /night/ => "0 2 * * *"
      }.freeze

      source_root File.expand_path("templates", __dir__)

      class_option :deployments, type: :array, default: [], desc: "Scheduled deployments, e.g. daily hourly-title"
      class_option :vault, type: :boolean, default: false, desc: "Add a vault.yaml for credentials"
      class_option :model, type: :string, default: "claude-opus-5-5", desc: "Claude model ID"

      desc "Scaffolds an agent: app/agents/NAME/ with its definition files and app/agents/NAME_agent.rb."

      def create_definition
        template "agent.md", "app/agents/#{file_name}/agent.md"
        template "environment.yaml", "app/agents/#{file_name}/environment.yaml"
        template "vault.yaml", "app/agents/#{file_name}/vault.yaml" if options[:vault]

        options[:deployments].each do |deployment|
          @deployment = deployment.to_s.parameterize
          template "deployment.yaml", "app/agents/#{file_name}/deployment-#{@deployment}.yaml"
        end
      end

      def create_agent_class
        template "agent.rb", "app/agents/#{file_name}_agent.rb"
      end

      private

      def file_name
        super.delete_suffix("_agent")
      end

      def agent_class_name
        "#{file_name.camelize}Agent"
      end

      def parent_class_name
        File.exist?(File.join(destination_root, "app/agents/application_agent.rb")) ? "ApplicationAgent" : "ManagedAgents::Agent"
      end

      def app_name
        Rails.application.class.module_parent_name.underscore.dasherize
      end

      def schedule
        SCHEDULES.find { |pattern, _| @deployment.match?(pattern) }&.last || "0 9 * * *"
      end

      def time_zone
        ActiveSupport::TimeZone[Rails.application.config.time_zone]&.tzinfo&.name || "UTC"
      end
    end
  end
end

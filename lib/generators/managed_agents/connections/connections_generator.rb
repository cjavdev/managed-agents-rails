require "rails/generators"
require "generators/managed_agents/shared/agent_access"

module ManagedAgents
  module Generators
    class ConnectionsGenerator < Rails::Generators::Base
      include AgentAccess

      source_root File.expand_path("templates", __dir__)

      desc "Generates a page where people connect the MCP servers your agents use, with OAuth or a token."

      def create_controller
        create_agent_access
        template "agent_connections_controller.rb", "app/controllers/agent_connections_controller.rb"
      end

      def create_view
        copy_file "index.html.erb", "app/views/agent_connections/index.html.erb"
        copy_file File.expand_path("../chat/templates/assets/managed_agents.css", __dir__),
          "app/assets/stylesheets/managed_agents.css", skip: true
      end

      def add_routes
        route <<~RUBY
          resources :agent_connections, only: [:index, :create, :destroy] do
            get :callback, on: :collection
          end
        RUBY
      end

      def show_notes
        return unless behavior == :invoke

        say <<~NOTES

          Connections page generated at /agent_connections.

            * It lists every MCP server declared in an agent.md.
            * Whose credentials can be managed is `agent_vault_owners` in
              app/controllers/concerns/agent_access.rb. Pass --organization to add shared ones.
            * Use them in a session with `vaults:`, or declare a default on the agent:
                vaults :owner, :agent
            * Servers without dynamic client registration need a client in config.oauth_clients.
            * To hear about expired authorizations, register the webhook endpoint and
              subscribe to vault_credential.refresh_failed.

        NOTES
      end
    end
  end
end

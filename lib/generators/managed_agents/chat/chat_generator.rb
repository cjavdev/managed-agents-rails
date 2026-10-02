require "rails/generators"
require "generators/managed_agents/shared/agent_access"

module ManagedAgents
  module Generators
    class ChatGenerator < Rails::Generators::Base
      include AgentAccess

      source_root File.expand_path("templates", __dir__)

      desc "Generates a chat UI for agent sessions: controllers, views, a Stimulus controller, a stylesheet and routes."

      def create_controllers
        create_agent_access
        template "controllers/agent_sessions_controller.rb", "app/controllers/agent_sessions_controller.rb"
        %w[messages confirmations interrupts].each do |name|
          template "controllers/agent_sessions/#{name}_controller.rb", "app/controllers/agent_sessions/#{name}_controller.rb"
        end
      end

      def create_views
        %w[index show _session _composer].each do |name|
          copy_file "views/#{name}.html.erb", "app/views/agent_sessions/#{name}.html.erb"
        end
      end

      def create_assets
        copy_file "assets/agent_chat_controller.js", "app/javascript/controllers/agent_chat_controller.js"
        copy_file "assets/managed_agents.css", "app/assets/stylesheets/managed_agents.css"
      end

      def add_routes
        route <<~RUBY
          resources :agent_sessions, only: [:index, :show, :create] do
            scope module: :agent_sessions do
              resources :messages, only: :create
              resources :confirmations, only: :create
              resource :interrupt, only: :create
            end
          end
        RUBY
      end

      def show_notes
        return unless behavior == :invoke

        say <<~NOTES

          Chat UI generated at /agent_sessions.

            * Sessions are scoped to `agent_owner` in app/controllers/concerns/agent_access.rb.
            * Live updates need turbo-rails and Action Cable (Solid Cable works).
            * Include the stylesheet if your layout doesn't load every stylesheet:
                <%= stylesheet_link_tag "managed_agents" %>
            * With a JavaScript bundler, run `bin/rails stimulus:manifest:update`.
            * To restyle individual events: bin/rails generate managed_agents:views
            * To let people connect their own MCP servers: bin/rails generate managed_agents:connections

        NOTES
        say "  No authentication was detected: agent_owner returns nil, so sessions are not scoped to a person yet.\n\n", :red if unscoped?
      end
    end
  end
end

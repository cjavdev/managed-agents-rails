module ManagedAgents
  module Generators
    # Shared by the generators that create controllers: writes the concern
    # that says who the signed-in person is to the agents.
    module AgentAccess
      def self.included(base)
        base.class_option :owner, type: :string,
          desc: "Ruby expression for who sessions belong to, e.g. current_user or Current.user"
        base.class_option :organization, type: :string,
          desc: "Ruby expression for the record holding shared credentials, e.g. current_user.account"
      end

      def create_agent_access
        template File.expand_path("agent_access.rb.tt", __dir__), "app/controllers/concerns/agent_access.rb", skip: true
      end

      private

      def owner_expression
        options[:owner] || detected_owner || "nil"
      end

      # Rails' authentication generator and Devise each have a conventional
      # way to reach the signed-in user.
      def detected_owner
        if File.exist?(File.join(destination_root, "app/controllers/concerns/authentication.rb")) then "Current.user"
        elsif File.exist?(File.join(destination_root, "config/initializers/devise.rb")) then "current_user"
        end
      end

      def vault_owners_expression
        owners = [%("personal" => agent_owner)]
        owners << %("organization" => #{options[:organization]}) if options[:organization]
        "{#{owners.join(", ")}}.compact"
      end

      def unscoped?
        owner_expression == "nil"
      end
    end
  end
end

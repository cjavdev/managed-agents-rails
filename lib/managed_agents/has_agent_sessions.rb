module ManagedAgents
  # Associations between the app's records and agent sessions and vaults.
  #
  #   class Ticket < ApplicationRecord
  #     has_agent_sessions                  # what agents work on
  #   end
  #
  #   class User < ApplicationRecord
  #     has_agent_sessions as: :owner       # who a session belongs to
  #     has_agent_vault                     # personal connections
  #   end
  #
  #   class Account < ApplicationRecord
  #     has_agent_vault                     # shared service accounts
  #   end
  #
  #   SupportTriageAgent.start("Triage", subject: ticket, owner: user, vaults: [user, user.account, :agent])
  module HasAgentSessions
    extend ActiveSupport::Concern

    class_methods do
      def has_agent_sessions(as: :subject, dependent: :nullify)
        has_many :agent_sessions, class_name: "ManagedAgents::Session", as: as, dependent: dependent
      end

      # `agent_vault` is nil until something is connected; `agent_vault!`
      # creates it. Pass a name for an additional group of credentials.
      # Destroying the record archives its vaults and their secrets.
      def has_agent_vault
        has_many :agent_vaults, class_name: "ManagedAgents::Vault", as: :owner, dependent: :destroy
        has_one :agent_vault, -> { where(name: ManagedAgents::Vault::DEFAULT) }, class_name: "ManagedAgents::Vault", as: :owner

        define_method(:agent_vault!) { |name = ManagedAgents::Vault::DEFAULT| ManagedAgents::Vault.for(self, name) }
        define_method(:agent_connections) { ManagedAgents::Connection.where(vault: agent_vaults) }
      end
    end
  end
end

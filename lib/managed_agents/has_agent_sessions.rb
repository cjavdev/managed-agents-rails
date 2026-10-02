module ManagedAgents
  # `has_agent_sessions` on a model makes it the subject agents work on:
  #
  #   class Ticket < ApplicationRecord
  #     has_agent_sessions
  #   end
  #
  #   SupportTriageAgent.start("Triage this ticket", subject: ticket)
  #   ticket.agent_sessions.recent
  module HasAgentSessions
    extend ActiveSupport::Concern

    class_methods do
      def has_agent_sessions(dependent: :nullify)
        has_many :agent_sessions, class_name: "ManagedAgents::Session", as: :subject, dependent: dependent
      end
    end
  end
end

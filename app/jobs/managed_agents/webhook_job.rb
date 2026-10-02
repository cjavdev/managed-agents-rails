module ManagedAgents
  # Webhook payloads only carry a type and an ID, and can arrive out of order,
  # so each one is handled by fetching current state.
  class WebhookJob < ApplicationJob
    SESSION_EVENTS = %w[
      session.status_run_started session.status_idled session.status_rescheduled session.status_terminated
    ].freeze

    def perform(type, id)
      ActiveSupport::Notifications.instrument("webhook.managed_agents", type: type, id: id) do
        case type
        when *SESSION_EVENTS then Session.find_by(remote_id: id)&.run_later
        when "deployment_run.succeeded" then Deployments.adopt(id)
        end
      end
    end
  end
end

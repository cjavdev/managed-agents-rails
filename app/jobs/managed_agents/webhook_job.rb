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
        when "vault_credential.refresh_failed" then Connection.find_by(remote_id: id)&.check!
        # Already gone on the API, so the local rows go without calling it.
        when "vault_credential.archived", "vault_credential.deleted" then Connection.where(remote_id: id).delete_all
        when "vault.archived", "vault.deleted" then forget_vault(id)
        end
      end
    end

    private

    def forget_vault(remote_id)
      vault = Vault.find_by(remote_id: remote_id) or return
      vault.connections.delete_all
      vault.delete
    end
  end
end

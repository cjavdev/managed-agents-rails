require "test_helper"

class WebhookJobTest < ActiveSupport::TestCase
  setup { sync }

  test "a session event starts a runner for a session this app knows" do
    session = SupportTriageAgent.start

    assert_enqueued_with(job: ManagedAgents::SessionJob, args: [session]) do
      ManagedAgents::WebhookJob.perform_now("session.status_idled", session.remote_id)
    end
  end

  test "events for unknown sessions are ignored" do
    assert_no_enqueued_jobs { ManagedAgents::WebhookJob.perform_now("session.status_idled", "sesn_unknown") }
  end

  test "a scheduled run that created a session is adopted" do
    deployment = resource("support_triage", "deployment", "daily")
    anthropic.beta.deployment_runs.store(ManagedAgents::Testing::Record.new(id: "drun_1", deployment_id: deployment.remote_id, session_id: "sesn_fired"))

    ManagedAgents::WebhookJob.perform_now("deployment_run.succeeded", "drun_1")

    assert_equal "daily", ManagedAgents::Session.find_by!(remote_id: "sesn_fired").deployment_key
  end

  test "every delivery is published for the app to subscribe to" do
    seen = []
    subscription = ActiveSupport::Notifications.subscribe("webhook.managed_agents") { |event| seen << event.payload }

    ManagedAgents::WebhookJob.perform_now("vault_credential.refresh_failed", "vcrd_1")

    assert_equal [{type: "vault_credential.refresh_failed", id: "vcrd_1"}], seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end
end

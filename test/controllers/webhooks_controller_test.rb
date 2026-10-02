require "test_helper"

class WebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "whsec_#{Base64.strict_encode64("0123456789abcdef0123456789abcdef")}".freeze

  setup do
    # Signatures are verified by the real SDK client.
    ManagedAgents.config.client = Anthropic::Client.new(api_key: "sk-ant-test")
    ManagedAgents.config.webhook_secret = SECRET
  end

  def deliver(type, id, secret: SECRET, timestamp: Time.now)
    body = {type: "event", id: "whe_1", created_at: Time.now.utc.iso8601, data: {type: type, id: id}}.to_json
    signature = StandardWebhooks::Webhook.new(secret).sign("whe_1", timestamp.to_i, body)
    post "/managed_agents/webhooks", params: body, headers: {
      "Content-Type" => "application/json",
      "webhook-id" => "whe_1",
      "webhook-timestamp" => timestamp.to_i.to_s,
      "webhook-signature" => signature
    }
  end

  test "a signed delivery is accepted and handled in a job" do
    assert_enqueued_with(job: ManagedAgents::WebhookJob, args: ["session.status_idled", "sesn_1"]) do
      deliver("session.status_idled", "sesn_1")
    end
    assert_response :no_content
  end

  test "a delivery signed with another secret is rejected" do
    other = "whsec_#{Base64.strict_encode64("another-secret-another-secret-00")}"

    assert_no_enqueued_jobs { deliver("session.status_idled", "sesn_1", secret: other) }
    assert_response :bad_request
  end

  test "a stale delivery is rejected" do
    assert_no_enqueued_jobs { deliver("session.status_idled", "sesn_1", timestamp: 1.hour.ago) }
    assert_response :bad_request
  end

  test "an unsigned request is rejected" do
    post "/managed_agents/webhooks", params: "{}", headers: {"Content-Type" => "application/json"}
    assert_response :bad_request
  end

  test "without a signing secret nothing is accepted" do
    ManagedAgents.config.webhook_secret = nil
    ManagedAgents.config.client = Anthropic::Client.new(api_key: "sk-ant-test", webhook_key: nil)

    deliver("session.status_idled", "sesn_1")
    assert_response :bad_request
  end
end

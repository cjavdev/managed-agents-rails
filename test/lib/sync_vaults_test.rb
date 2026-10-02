require "test_helper"

class SyncVaultsTest < ActiveSupport::TestCase
  test "creates the vault and a credential with the secret resolved from ENV" do
    sync

    assert_equal "dummy-support-triage", anthropic.calls_to(:"vlt.create").sole[:display_name]

    credential = anthropic.calls_to(:"vcrd.create").sole
    assert_equal resource("support_triage", "vault").remote_id, credential[:vault_id]
    assert_equal "Helpdesk MCP", credential[:display_name]
    assert_equal({type: "static_bearer", mcp_server_url: "https://mcp.helpdesk.example/mcp", token: "token-one"}, credential[:auth])
  end

  test "credentials are keyed by the MCP server URL" do
    sync
    assert resource("support_triage", "credential", "https://mcp.helpdesk.example/mcp")
  end

  test "the stored digest does not contain the secret" do
    sync
    refute_match "token-one", resource("support_triage", "credential", "https://mcp.helpdesk.example/mcp").attributes.to_json
  end

  test "a rotated secret updates the credential in place, without the immutable key" do
    sync
    ENV["HELPDESK_MCP_TOKEN"] = "token-two"

    changes, = sync

    assert_equal :update, changes.find { |change| change.kind == "credential" }.action
    update = anthropic.calls_to(:"vcrd.update").sole
    assert_equal({type: "static_bearer", token: "token-two"}, update[:auth])
    assert_empty anthropic.calls_to(:"vcrd.create").drop(1)
  end

  test "an unchanged secret is not sent again" do
    sync
    anthropic.calls.clear
    sync

    assert_empty anthropic.calls
  end

  test "a missing secret stops the sync and names the variable" do
    ENV.delete("HELPDESK_MCP_TOKEN")

    error = assert_raises(ManagedAgents::DefinitionError) { sync }
    assert_match "HELPDESK_MCP_TOKEN", error.message
    assert_empty anthropic.calls
  end

  test "environment variable credentials are keyed by secret name" do
    ENV["STRIPE_SECRET_KEY"] = "sk_test"
    with_agents(agent_files.merge("helper/vault.yaml" => <<~YAML))
      display_name: helper
      credentials:
        - display_name: Stripe
          auth:
            type: environment_variable
            secret_name: STRIPE_API_KEY
            secret_value: {env: STRIPE_SECRET_KEY}
            networking: {type: limited, allowed_hosts: [api.stripe.com]}
    YAML

    sync

    assert resource("helper", "credential", "STRIPE_API_KEY")
    auth = anthropic.calls_to(:"vcrd.create").sole[:auth]
    assert_equal "sk_test", auth[:secret_value]
    assert_equal ["api.stripe.com"], auth.dig(:networking, :allowed_hosts)
  ensure
    ENV.delete("STRIPE_SECRET_KEY")
  end

  test "a credential removed from vault.yaml is archived with --prune" do
    root = with_agents(agent_files.merge("helper/vault.yaml" => <<~YAML))
      display_name: helper
      credentials:
        - display_name: Helpdesk
          auth: {type: static_bearer, mcp_server_url: "https://mcp.example/mcp", token: {env: HELPDESK_MCP_TOKEN}}
    YAML
    sync
    File.write(root.join("helper/vault.yaml"), "display_name: helper\n")

    sync(prune: true)

    assert_nil resource("helper", "credential", "https://mcp.example/mcp")
    assert_equal 1, anthropic.calls_to(:"vcrd.archive").size
  end
end

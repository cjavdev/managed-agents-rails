require "test_helper"

class SecretsTest < ActiveSupport::TestCase
  setup do
    @credentials = {helpdesk: {mcp_token: "from-credentials"}, test: {stripe: {secret_key: "from-test-env"}}, stripe: {secret_key: "flat"}}
    credentials = @credentials
    Rails.application.credentials.define_singleton_method(:dig) { |*keys| credentials.dig(*keys) }
  end

  teardown do
    Rails.application.credentials.singleton_class.remove_method(:dig)
    ENV.delete("STRIPE_SECRET_KEY")
  end

  test "ENV wins over credentials" do
    assert_equal "token-one", ManagedAgents.secret("helpdesk.mcp_token")
  end

  test "falls back to credentials" do
    ENV.delete("HELPDESK_MCP_TOKEN")
    assert_equal "from-credentials", ManagedAgents.secret("helpdesk.mcp_token")
  end

  test "credentials scoped to the Rails environment win over flat ones" do
    assert_equal "from-test-env", ManagedAgents.secret("stripe.secret_key")
  end

  test "a missing secret names the ENV variable to set" do
    error = assert_raises(ManagedAgents::MissingSecret) { ManagedAgents.secret("linear.api_key") }
    assert_match "LINEAR_API_KEY", error.message
  end

  test "resolves references anywhere in an auth hash" do
    ENV["STRIPE_SECRET_KEY"] = "sk_live"
    auth = ManagedAgents::Secrets.resolve({
      "type" => "mcp_oauth",
      "access_token" => {"credential" => "helpdesk.mcp_token"},
      "refresh" => {"refresh_token" => {"env" => "STRIPE_SECRET_KEY"}, "client_id" => "abc"}
    })

    assert_equal "token-one", auth["access_token"]
    assert_equal "sk_live", auth.dig("refresh", "refresh_token")
    assert_equal "abc", auth.dig("refresh", "client_id")
  end

  test "refuses a literal value in a secret field" do
    error = assert_raises(ManagedAgents::DefinitionError) do
      ManagedAgents::Secrets.resolve({"type" => "static_bearer", "token" => "ghp_committed_by_mistake"})
    end
    assert_match "token must be a reference", error.message
  end

  test "an unset ENV reference raises" do
    assert_raises(ManagedAgents::MissingSecret) { ManagedAgents::Secrets.resolve({"token" => {"env" => "NOT_SET_ANYWHERE"}}) }
  end
end

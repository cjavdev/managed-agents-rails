require "test_helper"

class VaultTest < ActiveSupport::TestCase
  LINEAR = "https://mcp.linear.app/mcp".freeze

  setup do
    @account = Account.create!(name: "Acme")
    @user = User.create!(name: "Dana", account: @account)
  end

  test "a record has no vault until something is connected" do
    assert_nil @user.agent_vault
    assert_empty @user.agent_connections
    assert_empty anthropic.calls
  end

  test "the vault is created on the API once, tagged with its owner" do
    vault = @user.agent_vault!

    assert_equal vault, @user.agent_vault!
    assert_equal vault, @user.reload.agent_vault
    params = anthropic.calls_to(:"vlt.create").sole
    assert_equal "User #{@user.id}", params[:display_name]
    assert_equal({owner: @user.to_gid.to_s, name: "default"}, params[:metadata])
  end

  test "an owner can keep separate named groups of credentials" do
    billing = @account.agent_vault!(:billing)

    refute_equal billing, @account.agent_vault!
    assert_equal billing, ManagedAgents::Vault.for(@account, "billing")
    assert_equal %w[billing default], @account.agent_vaults.pluck(:name).sort
    assert_equal "Account #{@account.id} billing", anthropic.beta.vaults.retrieve(billing.remote_id).display_name
  end

  test "connect_bearer stores a static token and tracks the connection" do
    connection = @user.agent_vault!.connect_bearer(LINEAR, token: "lin_api_123", display_name: "Linear")

    params = anthropic.calls_to(:"vcrd.create").sole
    assert_equal @user.agent_vault.remote_id, params[:vault_id]
    assert_equal({type: "static_bearer", mcp_server_url: LINEAR, token: "lin_api_123"}, params[:auth])
    assert_equal ["static_bearer", LINEAR, "active"], connection.values_at(:kind, :key, :status)
    assert @user.agent_vault.connected?(LINEAR)
    refute_match "lin_api_123", connection.attributes.to_json, "the token is not kept locally"
  end

  test "URLs match the way the API matches them" do
    @user.agent_vault!.connect_bearer("HTTPS://MCP.Linear.app:443/mcp/", token: "t")

    assert @user.agent_vault.connected?(LINEAR)
    refute @user.agent_vault.connected?("https://mcp.linear.app/other")
  end

  test "connect_oauth stores the tokens and how to refresh them" do
    expires = Time.utc(2026, 10, 2, 12)
    @user.agent_vault!.connect_oauth(LINEAR, access_token: "at", refresh_token: "rt", expires_at: expires,
      token_endpoint: "https://linear.app/oauth/token", client_id: "client-1", scope: "read write", resource: LINEAR)

    auth = anthropic.calls_to(:"vcrd.create").sole[:auth]
    assert_equal "mcp_oauth", auth[:type]
    assert_equal "2026-10-02T12:00:00Z", auth[:expires_at]
    assert_equal({refresh_token: "rt", token_endpoint: "https://linear.app/oauth/token", client_id: "client-1",
      scope: "read write", resource: LINEAR, token_endpoint_auth: {type: "none"}}, auth[:refresh])
  end

  test "a confidential OAuth client sends its secret with the refresh settings" do
    @user.agent_vault!.connect_oauth(LINEAR, access_token: "at", refresh_token: "rt",
      token_endpoint: "https://linear.app/oauth/token", client_id: "client-1", client_secret: "shh", client_auth: :client_secret_basic)

    assert_equal({type: "client_secret_basic", client_secret: "shh"},
      anthropic.calls_to(:"vcrd.create").sole.dig(:auth, :refresh, :token_endpoint_auth))
  end

  test "an access token without a refresh token is stored on its own" do
    @user.agent_vault!.connect_oauth(LINEAR, access_token: "at")

    refute anthropic.calls_to(:"vcrd.create").sole[:auth].key?(:refresh)
  end

  test "connect_env stores a secret limited to the hosts it may be sent to" do
    connection = @account.agent_vault!.connect_env("STRIPE_API_KEY", value: "sk_live", allowed_hosts: "api.stripe.com")

    auth = anthropic.calls_to(:"vcrd.create").sole[:auth]
    assert_equal({type: "limited", allowed_hosts: ["api.stripe.com"]}, auth[:networking])
    assert_equal({header: true, body: false}, auth[:injection_location])
    assert_equal ["environment_variable", "STRIPE_API_KEY"], connection.values_at(:kind, :key)
    assert @account.agent_vault.connected?("STRIPE_API_KEY")
  end

  test "connecting again with a new secret rotates the credential in place" do
    vault = @user.agent_vault!
    first = vault.connect_bearer(LINEAR, token: "old")
    first.update!(status: "needs_reauthorization")

    second = vault.connect_bearer(LINEAR, token: "new")

    assert_equal first, second
    assert_equal "active", second.status
    update = anthropic.calls_to(:"vcrd.update").sole
    assert_equal({type: "static_bearer", token: "new"}, update[:auth])
    assert_equal 1, anthropic.calls_to(:"vcrd.create").size
  end

  test "connecting with a different kind of credential replaces the old one" do
    vault = @user.agent_vault!
    old = vault.connect_bearer(LINEAR, token: "old")

    replacement = vault.connect_oauth(LINEAR, access_token: "at")

    refute_equal old.remote_id, replacement.remote_id
    assert_equal [{id: old.remote_id}], anthropic.calls_to(:"vcrd.archive")
    assert_equal 1, vault.connections.count
  end

  test "disconnect archives the credential" do
    vault = @user.agent_vault!
    connection = vault.connect_bearer(LINEAR, token: "t")

    vault.disconnect(LINEAR)

    refute vault.connected?(LINEAR)
    assert anthropic.beta.vaults.credentials.retrieve(connection.remote_id).archived_at
  end

  test "destroying the owner archives its vaults" do
    remote_id = @user.agent_vault!.remote_id
    @user.agent_vault.connect_bearer(LINEAR, token: "t")

    @user.destroy!

    assert anthropic.beta.vaults.retrieve(remote_id).archived_at
    assert_equal 0, ManagedAgents::Vault.count
    assert_equal 0, ManagedAgents::Connection.count
  end

  test "a failed refresh that the API confirms as invalid needs the person to reconnect" do
    connection = @user.agent_vault!.connect_oauth(LINEAR, access_token: "at")
    anthropic.beta.vaults.credentials.validation_status = "invalid"

    connection.check!

    assert connection.needs_reauthorization?
    refute @user.agent_vault.connected?(LINEAR)
  end

  test "a transient validation error leaves the connection usable" do
    connection = @user.agent_vault!.connect_oauth(LINEAR, access_token: "at")
    anthropic.beta.vaults.credentials.validation_status = "unknown"

    assert connection.check!.usable?
  end
end

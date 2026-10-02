require "test_helper"

class OAuthTest < ActiveSupport::TestCase
  SERVER = "https://mcp.linear.app/mcp".freeze
  CALLBACK = "https://app.example.com/agent_connections/callback".freeze
  AUTH = "https://auth.linear.app".freeze

  setup do
    @user = User.create!(name: "Dana")
  end

  def json(body, status: 200, headers: {})
    {status: status, body: body.to_json, headers: {"Content-Type" => "application/json"}.merge(headers)}
  end

  # A server that follows the current MCP authorization spec.
  def stub_modern_server(registration: true, scopes: %w[read write])
    stub_request(:get, SERVER).to_return(status: 401, headers: {
      "WWW-Authenticate" => %(Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
    })
    stub_request(:get, "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
      .to_return(json({resource: SERVER, authorization_servers: [AUTH], scopes_supported: scopes}))
    metadata = {issuer: AUTH, authorization_endpoint: "#{AUTH}/authorize", token_endpoint: "#{AUTH}/token"}
    metadata[:registration_endpoint] = "#{AUTH}/register" if registration
    stub_request(:get, "#{AUTH}/.well-known/oauth-authorization-server").to_return(json(metadata))
    @registration = stub_request(:post, "#{AUTH}/register").to_return(json({client_id: "client-123"}, status: 201))
  end

  def stub_token(body = {access_token: "at-1", refresh_token: "rt-1", expires_in: 3600, scope: "read write"}, status: 200)
    @token = stub_request(:post, "#{AUTH}/token").to_return(json(body, status: status))
  end

  def authorize = ManagedAgents::OAuth.authorize(SERVER, redirect_uri: CALLBACK)

  def query_of(url) = URI.decode_www_form(URI.parse(url).query).to_h

  test "discovers the authorization server from the server's 401 response" do
    stub_modern_server

    metadata = ManagedAgents::OAuth::Discovery.new(SERVER).metadata

    assert_equal ["#{AUTH}/authorize", "#{AUTH}/token", "#{AUTH}/register"],
      metadata.to_h.values_at("authorization_endpoint", "token_endpoint", "registration_endpoint")
    assert_equal %w[read write], metadata.scopes
  end

  test "falls back to the well-known path when the server gives no pointer" do
    stub_request(:get, SERVER).to_return(status: 405)
    stub_request(:get, "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
      .to_return(json({authorization_servers: ["https://id.example.com/tenant"]}))
    stub_request(:get, "https://id.example.com/.well-known/oauth-authorization-server/tenant")
      .to_return(json({authorization_endpoint: "https://id.example.com/tenant/authorize", token_endpoint: "https://id.example.com/tenant/token"}))

    metadata = ManagedAgents::OAuth::Discovery.new(SERVER).metadata

    assert_equal "https://id.example.com/tenant/authorize", metadata.authorization_endpoint
    assert_nil metadata.registration_endpoint, "a server with metadata but no registration endpoint offers none"
  end

  test "assumes the default endpoints on servers that publish no metadata" do
    stub_request(:get, /mcp\.linear\.app/).to_return(status: 404)

    metadata = ManagedAgents::OAuth::Discovery.new(SERVER).metadata

    assert_equal ["https://mcp.linear.app/authorize", "https://mcp.linear.app/token", "https://mcp.linear.app/register"],
      metadata.to_h.values_at("authorization_endpoint", "token_endpoint", "registration_endpoint")
  end

  test "registers a public client once and reuses it for everyone" do
    stub_modern_server

    first = authorize
    second = authorize

    assert_requested @registration, times: 1
    assert_requested(:post, "#{AUTH}/register") do |request|
      body = JSON.parse(request.body)
      body["redirect_uris"] == [CALLBACK] && body["token_endpoint_auth_method"] == "none" &&
        body["grant_types"] == %w[authorization_code refresh_token] && body["client_name"] == "Dummy"
    end
    assert_equal "client-123", query_of(first.url)["client_id"]
    refute_equal first.state, second.state
    assert_equal 1, ManagedAgents::OAuthClient.count
  end

  test "the authorization URL carries a PKCE challenge, the resource and the scopes" do
    stub_modern_server

    pending = authorize
    query = query_of(pending.url)

    assert pending.url.start_with?("#{AUTH}/authorize?")
    assert_equal ["code", CALLBACK, pending.state, "S256", "read write", SERVER],
      query.values_at("response_type", "redirect_uri", "state", "code_challenge_method", "scope", "resource")
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(pending.code_verifier), padding: false), query["code_challenge"]
    refute_includes pending.url, pending.code_verifier
    assert_equal %w[code_verifier redirect_uri server_url state], pending.to_h.keys.sort, "what goes in the session"
  end

  test "completing the flow exchanges the code and stores refreshable tokens in the vault" do
    stub_modern_server
    stub_token
    pending = authorize

    connection = travel_to(Time.utc(2026, 10, 2, 12)) do
      ManagedAgents::OAuth.complete(@user.agent_vault!, pending.to_h, {state: pending.state, code: "code-1"})
    end

    assert_requested(:post, "#{AUTH}/token") do |request|
      form = URI.decode_www_form(request.body).to_h
      form == {"grant_type" => "authorization_code", "code" => "code-1", "redirect_uri" => CALLBACK,
               "code_verifier" => pending.code_verifier, "resource" => SERVER, "client_id" => "client-123"}
    end

    auth = anthropic.calls_to(:"vcrd.create").sole[:auth]
    assert_equal ["mcp_oauth", SERVER, "at-1", "2026-10-02T13:00:00Z"], auth.values_at(:type, :mcp_server_url, :access_token, :expires_at)
    assert_equal({refresh_token: "rt-1", token_endpoint: "#{AUTH}/token", client_id: "client-123", scope: "read write",
      resource: SERVER, token_endpoint_auth: {type: "none"}}, auth[:refresh])
    assert connection.usable?
    assert @user.agent_vault.connected?(SERVER)
    refute_match(/at-1|rt-1/, connection.attributes.to_json)
  end

  test "a response for a different request is rejected before any token request" do
    stub_modern_server
    stub_token
    pending = authorize

    error = assert_raises(ManagedAgents::OAuth::Rejected) do
      ManagedAgents::OAuth.complete(@user.agent_vault!, pending.to_h, {state: "forged", code: "code-1"})
    end

    assert_match "does not match", error.message
    assert_not_requested @token
  end

  test "a callback with nothing in progress is rejected" do
    assert_raises(ManagedAgents::OAuth::Rejected) do
      ManagedAgents::OAuth.complete(@user.agent_vault!, nil, {state: "", code: "code-1"})
    end
  end

  test "a person who declines sees the server's reason" do
    stub_modern_server
    pending = authorize

    error = assert_raises(ManagedAgents::OAuth::Rejected) do
      ManagedAgents::OAuth.complete(@user.agent_vault!, pending.to_h, {state: pending.state, error: "access_denied", error_description: "You cancelled"})
    end
    assert_equal "You cancelled", error.message
  end

  test "a failed token request reports the server's error and stores nothing" do
    stub_modern_server
    stub_token({error: "invalid_grant", error_description: "Code expired"}, status: 400)
    pending = authorize

    error = assert_raises(ManagedAgents::OAuth::Error) do
      ManagedAgents::OAuth.complete(@user.agent_vault!, pending.to_h, {state: pending.state, code: "old"})
    end
    assert_match "Code expired", error.message
    assert_empty anthropic.calls_to(:"vcrd.create")
  end

  test "a configured client is used instead of registering, with its secret" do
    stub_modern_server
    stub_token
    ManagedAgents.config.oauth_clients = {SERVER => {client_id: "configured", client_secret: "shh", scope: "issues:read"}}
    pending = authorize

    ManagedAgents::OAuth.complete(@user.agent_vault!, pending.to_h, {state: pending.state, code: "code-1"})

    assert_not_requested @registration
    assert_equal ["configured", "issues:read"], query_of(pending.url).values_at("client_id", "scope")
    assert_requested(:post, "#{AUTH}/token") do |request|
      URI.decode_www_form(request.body).to_h.slice("client_id", "client_secret") == {"client_id" => "configured", "client_secret" => "shh"}
    end
    assert_equal({type: "client_secret_post", client_secret: "shh"},
      anthropic.calls_to(:"vcrd.create").sole.dig(:auth, :refresh, :token_endpoint_auth))
  end

  test "a server without client registration asks for a configured client" do
    stub_modern_server(registration: false)

    error = assert_raises(ManagedAgents::OAuth::Error) { authorize }
    assert_match "config.oauth_clients", error.message
  end

  test "plain HTTP endpoints are refused, except on localhost" do
    error = assert_raises(ManagedAgents::OAuth::Error) { ManagedAgents::OAuth::HTTP.get("http://auth.example.com/token") }
    assert_match "must be HTTPS", error.message

    stub_request(:get, "http://localhost:3001/.well-known/x").to_return(json({ok: true}))
    assert ManagedAgents::OAuth::HTTP.get("http://localhost:3001/.well-known/x").ok?
  end

  test "reconnecting through the same client rotates the stored credential" do
    stub_modern_server
    stub_token
    vault = @user.agent_vault!
    2.times do
      pending = authorize
      ManagedAgents::OAuth.complete(vault, pending.to_h, {state: pending.state, code: "code"})
    end

    assert_equal 1, anthropic.calls_to(:"vcrd.create").size
    assert_equal 1, anthropic.calls_to(:"vcrd.update").size
    assert_equal 1, vault.connections.count
  end
end

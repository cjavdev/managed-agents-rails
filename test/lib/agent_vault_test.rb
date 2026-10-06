require "test_helper"

class AgentVaultTest < ActiveSupport::TestCase
  SERVER = "https://mcp.sentry.example/mcp".freeze
  AUTH = "https://auth.sentry.example".freeze
  CALLBACK = "http://localhost:8976/callback".freeze

  def fixer_files(credential = nil)
    credential ||= <<~YAML
      - display_name: Sentry
        connect: oauth
        scope: org:read event:write
        auth:
          type: mcp_oauth
          mcp_server_url: #{SERVER}
    YAML
    agent_files("fixer", agent: <<~MD).merge("fixer/vault.yaml" => "display_name: fixer\ncredentials:\n#{credential.indent(2)}")
      ---
      name: Fixer
      model: claude-opus-5-5
      mcp_servers:
        - {type: url, name: sentry, url: #{SERVER}}
      ---

      You fix things.
    MD
  end

  def json(body, status: 200)
    {status: status, body: body.to_json, headers: {"Content-Type" => "application/json"}}
  end

  def stub_server(access_token: "at-1")
    stub_request(:get, SERVER).to_return(status: 401, headers: {
      "WWW-Authenticate" => %(Bearer resource_metadata="https://mcp.sentry.example/.well-known/oauth-protected-resource/mcp")
    })
    stub_request(:get, "https://mcp.sentry.example/.well-known/oauth-protected-resource/mcp")
      .to_return(json({resource: SERVER, authorization_servers: [AUTH], scopes_supported: %w[org:read org:write event:write]}))
    stub_request(:get, "#{AUTH}/.well-known/oauth-authorization-server").to_return(json(
      {issuer: AUTH, authorization_endpoint: "#{AUTH}/authorize", token_endpoint: "#{AUTH}/token", registration_endpoint: "#{AUTH}/register"}
    ))
    stub_request(:post, "#{AUTH}/register").to_return(json({client_id: "client-9"}, status: 201))
    stub_request(:post, "#{AUTH}/token").to_return(json({access_token: access_token, refresh_token: "rt-1", expires_in: 3600}))
  end

  # Runs the terminal flow, answering it with the address the browser lands on.
  def connect(vault = ManagedAgents::AgentVault.new("fixer"), output: StringIO.new)
    input = Object.new
    input.define_singleton_method(:gets) do
      url = output.string[%r{https://auth\S+}]
      state = URI.decode_www_form(URI.parse(url).query).to_h["state"]
      "#{CALLBACK}?code=code-1&state=#{state}\n"
    end
    ManagedAgents::OAuth::Terminal.new(vault, SERVER, redirect_uri: CALLBACK, scope: vault.credential(SERVER)["scope"],
      input: input, output: output, listen: false).run
    output.string
  end

  test "sync creates the vault but leaves a connect: oauth credential to be signed in for" do
    with_agents(fixer_files)
    changes, output = sync

    assert_equal :not_connected, changes.find { |change| change.kind == "credential" }.action
    assert_empty anthropic.calls_to(:"vcrd.create")
    assert_match "managed_agents:connect fixer #{SERVER}", output
    assert_match "1 not connected", output
    assert_equal "not connected", ManagedAgents::Sync.new(io: StringIO.new).status.find { |row| row[1].start_with?("credential") }.last
    assert_equal [SERVER], ManagedAgents.agent("fixer").missing_connections.map(&:url)
  end

  test "connecting signs in with the declared scope and stores refreshable tokens in the agent's vault" do
    with_agents(fixer_files)
    sync
    stub_server

    output = connect

    assert_equal "org:read event:write", URI.decode_www_form(URI.parse(output[%r{https://auth\S+}]).query).to_h["scope"]
    params = anthropic.calls_to(:"vcrd.create").sole
    assert_equal resource("fixer", "vault").remote_id, params[:vault_id]
    assert_equal "Sentry", params[:display_name]
    assert_equal ["mcp_oauth", SERVER, "at-1"], params[:auth].values_at(:type, :mcp_server_url, :access_token)
    assert_equal({refresh_token: "rt-1", token_endpoint: "#{AUTH}/token", client_id: "client-9", scope: "org:read event:write",
      resource: SERVER, token_endpoint_auth: {type: "none"}}, params[:auth][:refresh])

    assert_equal anthropic.beta.vaults.credentials.records.keys.sole, resource("fixer", "credential", SERVER).remote_id
    refute_match(/at-1|rt-1/, resource("fixer", "credential", SERVER).attributes.to_json)
    assert_empty ManagedAgents.agent("fixer").missing_connections

    changes, = sync
    assert_equal [:unchanged], changes.map(&:action).uniq, "sync leaves a connected credential alone"
    assert_equal "connected", ManagedAgents::Sync.new(io: StringIO.new).status.find { |row| row[1].start_with?("credential") }.last
  end

  test "connecting again rotates the tokens in place" do
    with_agents(fixer_files)
    sync
    stub_server
    connect
    stub_server(access_token: "at-2")

    connect

    assert_equal 1, anthropic.calls_to(:"vcrd.create").size
    assert_equal "at-2", anthropic.calls_to(:"vcrd.update").sole.dig(:auth, :access_token)
  end

  test "status --validate asks the API whether a connected credential still works" do
    with_agents(fixer_files)
    sync
    stub_server
    connect
    credential_row = ->(status) { status.find { |row| row[1].start_with?("credential") }.last }

    assert_equal "connected", credential_row.call(ManagedAgents::Sync.new(io: StringIO.new).status(validate: true))
    anthropic.beta.vaults.credentials.validation_status = "invalid"
    assert_equal "invalid: reconnect", credential_row.call(ManagedAgents::Sync.new(io: StringIO.new).status(validate: true))
    anthropic.beta.vaults.credentials.validation_status = "unknown"
    assert_equal "connected (unverified)", credential_row.call(ManagedAgents::Sync.new(io: StringIO.new).status(validate: true))
  end

  test "only servers vault.yaml declares with connect: oauth can be connected" do
    with_agents(fixer_files)
    sync

    error = assert_raises(ManagedAgents::DefinitionError) { ManagedAgents::AgentVault.new("fixer").credential("https://other.example/mcp") }
    assert_match "declares no credential", error.message
  end

  test "a connected credential with tokens or the wrong type in the file is a problem" do
    with_agents(fixer_files(<<~YAML))
      - display_name: Sentry
        connect: yes-please
        auth:
          type: static_bearer
          mcp_server_url: #{SERVER}
          token: {credential: sentry.token}
    YAML

    problems = ManagedAgents.definition("fixer").problems.join("\n")
    assert_match "connect must be oauth", problems
    assert_match "needs auth.type mcp_oauth", problems
    assert_match "token come from signing in", problems
  end

  test "reads the callback from a pasted address" do
    params = ManagedAgents::OAuth::Terminal.params_from("#{CALLBACK}?code=abc&state=xyz\n")

    assert_equal %w[abc xyz], params.values_at(:code, :state)
  end
end

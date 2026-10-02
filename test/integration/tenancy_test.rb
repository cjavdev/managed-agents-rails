require "test_helper"

# Who can see which sessions, and whose credentials a person can manage.
class TenancyTest < ActionDispatch::IntegrationTest
  LINEAR = "https://mcp.linear.app/mcp".freeze
  AUTH = "https://auth.linear.app".freeze

  setup do
    with_agents(agent_files("researcher", agent: <<~MD))
      ---
      name: Researcher
      model: claude-opus-5-5
      mcp_servers:
        - {type: url, name: linear, url: "#{LINEAR}"}
      tools:
        - {type: mcp_toolset, mcp_server_name: linear}
      ---

      You research issues.
    MD
    sync
    @acme = Account.create!(name: "Acme")
    @dana = User.create!(name: "Dana", account: @acme)
    @sam = User.create!(name: "Sam", account: @acme)
    @mallory = User.create!(name: "Mallory", account: Account.create!(name: "Other"))
  end

  def sign_in(user)
    cookies[:user_id] = user.id.to_s
  end

  def stub_authorization_server
    stub_request(:get, LINEAR).to_return(status: 401)
    stub_request(:get, %r{mcp\.linear\.app/\.well-known/oauth-protected-resource})
      .to_return(body: {authorization_servers: [AUTH]}.to_json, headers: {"Content-Type" => "application/json"})
    stub_request(:get, "#{AUTH}/.well-known/oauth-authorization-server").to_return(
      body: {authorization_endpoint: "#{AUTH}/authorize", token_endpoint: "#{AUTH}/token", registration_endpoint: "#{AUTH}/register"}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
    stub_request(:post, "#{AUTH}/register").to_return(body: {client_id: "client-1"}.to_json, headers: {"Content-Type" => "application/json"})
    stub_request(:post, "#{AUTH}/token").to_return(
      body: {access_token: "at", refresh_token: "rt", expires_in: 3600}.to_json, headers: {"Content-Type" => "application/json"}
    )
  end

  test "a session started from the chat belongs to the person who started it" do
    sign_in @dana
    post agent_sessions_path, params: {agent: "researcher", message: "What is open?"}

    assert_equal @dana, ManagedAgents::Session.order(:id).last.owner
  end

  test "people only see their own sessions" do
    danas = ManagedAgents.agent("researcher").start(owner: @dana, title: "Dana's research")
    ManagedAgents.agent("researcher").start(owner: @sam, title: "Sam's research")

    sign_in @dana
    get agent_sessions_path

    assert_select ".ma-session-list__item a", text: "Dana's research"
    assert_select ".ma-session-list__item a", text: "Sam's research", count: 0
    get agent_session_path(danas)
    assert_response :success
  end

  test "someone else's session cannot be opened, messaged, interrupted or approved by ID" do
    sams = ManagedAgents.agent("researcher").start(owner: @sam)
    ask = sams.record(tool_use("bash", {command: "ls"}, permission: "ask"))
    sign_in @dana

    get agent_session_path(sams)
    assert_response :not_found
    post agent_session_messages_path(sams), params: {message: "Hello"}
    assert_response :not_found
    post agent_session_interrupt_path(sams)
    assert_response :not_found
    post agent_session_confirmations_path(sams), params: {event_id: ask.id, result: "allow"}
    assert_response :not_found

    assert_empty anthropic.sent_events
  end

  test "the chat index says which agents are missing a connection" do
    sign_in @dana
    get agent_sessions_path

    assert_select ".ma-note", text: /Researcher has no credentials for Linear/
    assert_select ".ma-note a[href='#{agent_connections_path}']"
  end

  test "the connections page lists each declared server for the person and their organisation" do
    @acme.agent_vault!.connect_bearer(LINEAR, token: "t")
    sign_in @dana
    get agent_connections_path

    assert_response :success
    assert_select ".ma-connection h2", text: "Linear"
    assert_select ".ma-connection__row", count: 2
    assert_select ".ma-connection__row", text: /Personal\s+Not connected/
    assert_select ".ma-connection__row", text: /Organization\s+Connected/
  end

  test "signed out, there is nothing to manage" do
    get agent_connections_path

    assert_select ".ma-connection__row", count: 0
    assert_select ".ma-note", text: /Sign in/
  end

  test "saving a token connects the server for the chosen group only" do
    sign_in @dana
    post agent_connections_path, params: {server_url: LINEAR, group: "personal", token: "lin_api_1"}

    assert_redirected_to agent_connections_path
    assert @dana.agent_vault.connected?(LINEAR)
    assert_nil @acme.agent_vault
    assert_equal "lin_api_1", anthropic.calls_to(:"vcrd.create").sole.dig(:auth, :token)
  end

  test "connecting with OAuth sends the person to authorize and stores the tokens when they return" do
    stub_authorization_server
    sign_in @dana

    post agent_connections_path, params: {server_url: LINEAR, group: "organization"}

    assert_response :redirect
    location = URI.parse(response.location)
    query = URI.decode_www_form(location.query).to_h
    assert_equal "auth.linear.app", location.host
    assert_equal callback_agent_connections_url, query["redirect_uri"]

    get callback_agent_connections_path, params: {state: query["state"], code: "code-1"}

    assert_redirected_to agent_connections_path
    assert @acme.agent_vault.connected?(LINEAR), "the shared vault was the one chosen"
    assert_nil @dana.agent_vault
    assert_equal "mcp_oauth", anthropic.calls_to(:"vcrd.create").sole.dig(:auth, :type)
  end

  test "a callback with a forged state stores nothing" do
    stub_authorization_server
    sign_in @dana
    post agent_connections_path, params: {server_url: LINEAR, group: "personal"}

    get callback_agent_connections_path, params: {state: "forged", code: "code-1"}

    assert_redirected_to agent_connections_path
    assert_match "does not match", flash[:alert]
    assert_empty anthropic.calls_to(:"vcrd.create")
    assert_not_requested :post, "#{AUTH}/token"
  end

  test "a callback cannot be replayed" do
    stub_authorization_server
    sign_in @dana
    post agent_connections_path, params: {server_url: LINEAR, group: "personal"}
    state = URI.decode_www_form(URI.parse(response.location).query).to_h["state"]
    get callback_agent_connections_path, params: {state: state, code: "code-1"}

    get callback_agent_connections_path, params: {state: state, code: "code-1"}

    assert_match "No connection was in progress", flash[:alert]
    assert_equal 1, anthropic.calls_to(:"vcrd.create").size
  end

  test "only servers an agent declares can be connected" do
    sign_in @dana
    post agent_connections_path, params: {server_url: "https://evil.example/mcp", group: "personal", token: "t"}

    assert_response :not_found
    assert_empty anthropic.calls_to(:"vcrd.create")
  end

  test "a person cannot manage a group they are not offered" do
    sign_in @dana
    post agent_connections_path, params: {server_url: LINEAR, group: "admin", token: "t"}

    assert_response :not_found
  end

  test "disconnecting is limited to the person's own vaults" do
    theirs = @mallory.agent_vault!.connect_bearer(LINEAR, token: "t")
    mine = @dana.agent_vault!.connect_bearer(LINEAR, token: "t")
    sign_in @dana

    delete agent_connection_path(theirs)
    assert_response :not_found
    assert theirs.reload.usable?

    delete agent_connection_path(mine)
    assert_redirected_to agent_connections_path
    refute @dana.agent_vault.connected?(LINEAR)
  end

  test "a session uses personal credentials first, then the organisation's" do
    @dana.agent_vault!.connect_bearer(LINEAR, token: "danas")
    @acme.agent_vault!.connect_bearer(LINEAR, token: "shared")
    agent = ManagedAgents.agent("researcher")

    agent.start(owner: @dana, vaults: [:owner, :account])
    assert_equal [@dana.agent_vault.remote_id, @acme.agent_vault.remote_id], anthropic.calls_to(:"sesn.create").last[:vault_ids]

    agent.start(owner: @sam, vaults: [:owner, :account])
    assert_equal [@acme.agent_vault.remote_id], anthropic.calls_to(:"sesn.create").last[:vault_ids], "Sam has connected nothing personally"

    assert_empty agent.missing_connections(owner: @sam, vaults: [:owner, :account])
    assert_equal ["linear"], agent.missing_connections(owner: @mallory, vaults: [:owner, :account]).map(&:name)
  end
end

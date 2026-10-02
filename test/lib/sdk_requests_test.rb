require "test_helper"

# Runs the real SDK against stubbed HTTP, so the parameter names and paths the
# engine uses are checked against the installed anthropic gem rather than the
# in-memory fake.
class SdkRequestsTest < ActiveSupport::TestCase
  API = "https://api.anthropic.com/v1".freeze

  setup do
    ManagedAgents.config.client = Anthropic::Client.new(api_key: "sk-ant-test", max_retries: 0)
    @requests = []
  end

  def stub_api(method, path, response, query: {})
    stub_request(method, "#{API}/#{path}").with(query: {"beta" => "true"}.merge(query)).to_return do |request|
      @requests << [method, path, request.body.present? ? JSON.parse(request.body) : nil, request.headers]
      body = response.respond_to?(:call) ? response.call(request) : response
      body.is_a?(String) ? {status: 200, body: body, headers: {"content-type" => "text/event-stream"}} :
        {status: 200, body: body.to_json, headers: {"content-type" => "application/json"}}
    end
  end

  def body_of(method, path)
    @requests.find { |request| request.first(2) == [method, path] }&.at(2)
  end

  def sse(*events)
    events.map { |event| "event: #{event[:type]}\ndata: #{event.to_json}\n\n" }.join
  end

  test "sync creates every resource with the bodies from the definition files" do
    stub_api(:post, "environments", {id: "env_1", type: "environment", name: "dummy-support-triage-test"})
    stub_api(:post, "vaults", {id: "vlt_1", type: "vault", display_name: "dummy-support-triage"})
    stub_api(:post, "vaults/vlt_1/credentials", {id: "vcrd_1", type: "vault_credential", vault_id: "vlt_1"})
    stub_api(:post, "agents", {id: "agent_1", type: "agent", version: 1, name: "Support triage"})
    stub_api(:post, "deployments", {id: "depl_1", type: "deployment", name: "Support triage daily", status: "active"})

    ManagedAgents::Sync.new(backend: :api, io: StringIO.new).apply

    agent = body_of(:post, "agents")
    assert_equal "Support triage", agent["name"]
    assert_equal "claude-opus-5-5", agent["model"]
    assert_match "You triage support tickets", agent["system"], "the SDK's system_ is sent as system"
    assert_equal %w[agent_toolset_20260401 custom], agent["tools"].map { |tool| tool["type"] }
    assert_equal ["priority"], agent["tools"].last.dig("input_schema", "required")

    assert_equal({"type" => "cloud", "networking" => {"type" => "limited"}}, body_of(:post, "environments")["config"])

    credential = body_of(:post, "vaults/vlt_1/credentials")
    assert_equal({"type" => "static_bearer", "mcp_server_url" => "https://mcp.helpdesk.example/mcp", "token" => "token-one"}, credential["auth"])

    deployment = body_of(:post, "deployments")
    assert_equal({"type" => "agent", "id" => "agent_1", "version" => 1}, deployment["agent"])
    assert_equal "env_1", deployment["environment_id"]
    assert_equal ["vlt_1"], deployment["vault_ids"]
    assert_equal({"type" => "cron", "expression" => "0 9 * * *", "timezone" => "UTC"}, deployment["schedule"])

    assert @requests.all? { |*, headers| headers["Anthropic-Beta"].to_s.include?("managed-agents-2026-04-01") }
    assert_equal "1", resource("support_triage", "agent").remote_version
  end

  test "an agent update sends the current version and explicit nulls for removed fields" do
    root = with_agents(agent_files("helper", agent: "---\nname: Helper\nmodel: claude-opus-5-5\ndescription: Helps\n---\n\nYou help.\n"))
    stub_api(:post, "environments", {id: "env_1", type: "environment", name: "helper-env"})
    stub_api(:post, "agents", {id: "agent_1", type: "agent", version: 4, name: "Helper"})
    ManagedAgents::Sync.new(backend: :api, io: StringIO.new).apply

    File.write(root.join("helper/agent.md"), "---\nname: Helper\nmodel: claude-opus-5-5\n---\n")
    stub_api(:get, "agents/agent_1", {id: "agent_1", type: "agent", version: 4, name: "Helper"})
    stub_api(:post, "agents/agent_1", {id: "agent_1", type: "agent", version: 5, name: "Helper"})
    ManagedAgents::Sync.new(backend: :api, io: StringIO.new).apply

    update = body_of(:post, "agents/agent_1")
    assert_equal 4, update["version"]
    assert update.key?("system") && update["system"].nil?, "system is cleared with an explicit null"
    assert update.key?("description") && update["description"].nil?
    assert_equal [], update["tools"]
    assert_equal "5", resource("helper", "agent").remote_version
  end

  test "a person's vault and OAuth credential are created with the shapes the API expects" do
    user = User.create!(name: "Dana")
    stub_api(:post, "vaults", {id: "vlt_9", type: "vault", display_name: "User #{user.id}"})
    stub_api(:post, "vaults/vlt_9/credentials", {id: "vcrd_9", type: "vault_credential", vault_id: "vlt_9"})
    stub_api(:post, "vaults/vlt_9/credentials/vcrd_9", {id: "vcrd_9", type: "vault_credential", vault_id: "vlt_9"})
    stub_api(:post, "vaults/vlt_9/credentials/vcrd_9/mcp_oauth_validate",
      {type: "vault_credential_validation", credential_id: "vcrd_9", vault_id: "vlt_9", status: "invalid"})

    vault = user.agent_vault!
    connection = vault.connect_oauth("https://mcp.linear.app/mcp", access_token: "at", refresh_token: "rt",
      expires_at: Time.utc(2026, 10, 2, 12), token_endpoint: "https://linear.app/oauth/token", client_id: "client-1", scope: "read")

    assert_equal({"display_name" => "User #{user.id}", "metadata" => {"owner" => user.to_gid.to_s, "name" => "default"}}, body_of(:post, "vaults"))
    created = body_of(:post, "vaults/vlt_9/credentials")
    refute created.key?("display_name"), "an unset display name is left out rather than sent as null"
    assert_equal({"type" => "mcp_oauth", "mcp_server_url" => "https://mcp.linear.app/mcp", "access_token" => "at",
      "expires_at" => "2026-10-02T12:00:00Z",
      "refresh" => {"refresh_token" => "rt", "token_endpoint" => "https://linear.app/oauth/token", "client_id" => "client-1",
                    "scope" => "read", "token_endpoint_auth" => {"type" => "none"}}}, created["auth"])

    vault.connect_oauth("https://mcp.linear.app/mcp", access_token: "at-2", refresh_token: "rt-2",
      token_endpoint: "https://linear.app/oauth/token", client_id: "client-1", scope: "read")
    rotated = body_of(:post, "vaults/vlt_9/credentials/vcrd_9")
    assert_equal({"type" => "mcp_oauth", "access_token" => "at-2",
      "refresh" => {"refresh_token" => "rt-2", "scope" => "read", "token_endpoint_auth" => {"type" => "none"}}}, rotated["auth"])

    assert connection.check!.needs_reauthorization?
  end

  test "starting a session and following it works against the SDK's event types" do
    ManagedAgents::Testing::FakeClient.new.then do |fake|
      ManagedAgents.config.client = fake
      ManagedAgents::Sync.new(backend: :api, io: StringIO.new).apply
      ManagedAgents.config.client = Anthropic::Client.new(api_key: "sk-ant-test", max_retries: 0)
    end
    ticket = Ticket.create!(subject: "Refund")
    agent_id = resource("support_triage", "agent").remote_id

    kickoff = {id: "sevt_1", type: "user.message", content: [{type: "text", text: "Triage this"}], processed_at: "2026-10-01T12:00:00Z"}
    stub_api(:post, "sessions", {id: "sesn_1", type: "session", status: "idle"})
    sent = stub_api(:post, "sessions/sesn_1/events", {data: [kickoff]})
    session = SupportTriageAgent.start("Triage this", subject: ticket, max_cost: 1, run: false)

    create = body_of(:post, "sessions")
    assert_equal({"type" => "agent", "id" => agent_id, "version" => 1}, create["agent"])
    assert_equal({"type" => "limit", "max_list_cost" => {"amount" => "100", "currency" => "USD"}}, create["budget"])
    assert_equal "user.message", body_of(:post, "sessions/sesn_1/events")["events"].sole["type"]
    assert_equal ["sevt_1"], session.events.pluck(:remote_id)
    remove_request_stub(sent)
    @requests.clear

    tool_use = {id: "sevt_2", type: "agent.custom_tool_use", name: "set_priority", input: {priority: "high"}, processed_at: "2026-10-01T12:00:01Z"}
    stub_api(:get, "sessions/sesn_1/events", {data: [kickoff], next_page: nil}, query: {"order" => "asc"})
    stub_api(:get, "sessions/sesn_1/events/stream", sse(
      {type: "event_start", event: {type: "agent.message", id: "sevt_4"}},
      {type: "event_delta", event_id: "sevt_4", delta: {type: "content_delta", index: 0, content: {type: "text", text: "Set"}}},
      tool_use,
      {id: "sevt_3", type: "session.status_idle", stop_reason: {type: "requires_action", event_ids: ["sevt_2"]}, processed_at: "2026-10-01T12:00:02Z"},
      {id: "sevt_4", type: "agent.message", content: [{type: "text", text: "Set to high."}], processed_at: "2026-10-01T12:00:03Z"},
      {id: "sevt_5", type: "session.status_idle", stop_reason: {type: "end_turn"}, processed_at: "2026-10-01T12:00:04Z"}
    ), query: {"event_deltas[]" => "agent.message"})
    stub_api(:post, "sessions/sesn_1/events", ->(request) {
      {data: JSON.parse(request.body)["events"].map { |event| event.merge("id" => "sevt_r", "processed_at" => "2026-10-01T12:00:02Z") }}
    })
    stub_api(:get, "sessions/sesn_1", {id: "sesn_1", type: "session", status: "idle",
      usage: {input_tokens: 1200, output_tokens: 300, list_cost: {amount: "42", currency: "USD"}}})

    assert_equal :done, session.run_now

    result = body_of(:post, "sessions/sesn_1/events")["events"].sole
    assert_equal "user.custom_tool_result", result["type"]
    assert_equal "sevt_2", result["custom_tool_use_id"]
    assert_equal false, result["is_error"]
    assert_equal({"ok" => true, "priority" => "high"}, JSON.parse(result.dig("content", 0, "text")))

    assert_equal "high", ticket.reload.priority
    assert_equal "Set to high.", ticket.summary
    assert_equal %w[user.message agent.custom_tool_use user.custom_tool_result session.status_idle agent.message session.status_idle],
      session.events.pluck(:event_type)
    assert_equal "end_turn", session.reload.stop_reason
    assert_equal 0.42, session.list_cost
  end
end

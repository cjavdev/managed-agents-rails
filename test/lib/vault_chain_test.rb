require "test_helper"

class VaultChainTest < ActiveSupport::TestCase
  HELPDESK = "https://mcp.helpdesk.example/mcp".freeze
  LINEAR = "https://mcp.linear.app/mcp".freeze

  setup do
    sync
    @account = Account.create!(name: "Acme")
    @user = User.create!(name: "Dana", account: @account)
    @personal = @user.agent_vault!
    @shared = @account.agent_vault!
    @agent_vault_id = resource("support_triage", "vault").remote_id
  end

  def chain(sources, owner: @user)
    ManagedAgents::VaultChain.new(sources, agent: SupportTriageAgent, owner: owner)
  end

  def started_with
    anthropic.calls_to(:"sesn.create").last[:vault_ids]
  end

  test "by default a session only gets the agent's own vault" do
    SupportTriageAgent.start(owner: @user)

    assert_equal [@agent_vault_id], started_with
  end

  test "personal and account vaults are attached in the order given" do
    session = SupportTriageAgent.start(owner: @user, vaults: [@user, @user.account, :agent])

    assert_equal [@personal.remote_id, @shared.remote_id, @agent_vault_id], started_with
    assert_equal started_with, session.vault_ids
    assert_equal @user, session.owner
  end

  test "account credentials only" do
    SupportTriageAgent.start(owner: @user, vaults: [@user.account])

    assert_equal [@shared.remote_id], started_with
  end

  test "personal credentials only" do
    SupportTriageAgent.start(owner: @user, vaults: [@user])

    assert_equal [@personal.remote_id], started_with
  end

  test "no vaults at all" do
    SupportTriageAgent.start(owner: @user, vaults: [])

    assert_nil started_with
  end

  test "symbols resolve against the session owner" do
    assert_equal [@personal.remote_id, @shared.remote_id, @agent_vault_id], chain(%i[owner account agent]).remote_ids
  end

  test "asking for the owner's vault without an owner is an error, not a silent skip" do
    error = assert_raises(ArgumentError) { SupportTriageAgent.start(vaults: [:owner, :agent]) }
    assert_match "needs an owner", error.message
    assert_empty anthropic.calls_to(:"sesn.create")
  end

  test "an agent can declare its default chain" do
    agent = Class.new(SupportTriageAgent) { vaults :owner, :account, :agent }

    agent.start(owner: @user)

    assert_equal [@personal.remote_id, @shared.remote_id, @agent_vault_id], started_with
    assert_equal [:agent], SupportTriageAgent.default_vaults, "the declaration does not leak to the parent"
  end

  test "someone who has connected nothing is skipped" do
    newcomer = User.create!(name: "Sam", account: @account)

    assert_equal [@shared.remote_id], chain([newcomer, newcomer.account], owner: newcomer).remote_ids
  end

  test "named vaults and raw IDs can be mixed in" do
    billing = @account.agent_vault!(:billing)

    assert_equal [billing.remote_id, "vlt_external"], chain([billing, "vlt_external"]).remote_ids
  end

  test "the same vault is not attached twice" do
    assert_equal [@personal.remote_id], chain([@user, :owner, @personal]).remote_ids
  end

  test "covers? knows which servers the chain can authenticate to" do
    @shared.connect_bearer(LINEAR, token: "t")

    assert chain([@user, @account]).covers?(LINEAR)
    refute chain([@user]).covers?(LINEAR)
    assert chain([:agent]).covers?(HELPDESK), "credentials from vault.yaml count"
  end

  test "a connection that needs reauthorization does not count" do
    @personal.connect_oauth(LINEAR, access_token: "at").update!(status: "needs_reauthorization")

    refute chain([@user]).covers?(LINEAR)
  end

  test "missing_connections lists declared servers nobody in the chain has connected" do
    with_agents(agent_files("researcher", agent: <<~MD))
      ---
      name: Researcher
      model: claude-opus-5-5
      mcp_servers:
        - {type: url, name: linear, url: "#{LINEAR}"}
        - {type: url, name: notion, url: "https://mcp.notion.com/mcp"}
      ---
    MD
    sync
    agent = ManagedAgents.agent("researcher")
    @shared.connect_bearer(LINEAR, token: "t")

    assert_equal %w[linear notion], agent.missing_connections.map(&:name)
    assert_equal %w[linear notion], agent.missing_connections(owner: @user, vaults: [@user]).map(&:name)
    assert_equal %w[notion], agent.missing_connections(owner: @user, vaults: [@user, @account]).map(&:name)
  end

  test "tool handlers can see who the session belongs to" do
    session = SupportTriageAgent.start(owner: @user)

    assert_equal @user, SupportTriageAgent.new(session).owner
  end

  test "an owner's sessions are reachable from the owner" do
    mine = SupportTriageAgent.start(owner: @user)
    SupportTriageAgent.start(owner: User.create!(name: "Sam"))

    assert_equal [mine], @user.agent_sessions.to_a
    assert_equal [mine], ManagedAgents::Session.owned_by(@user).to_a
  end
end

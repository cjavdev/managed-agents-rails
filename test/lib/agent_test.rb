require "test_helper"

class AgentTest < ActiveSupport::TestCase
  setup { sync }

  test "finds the app's class for an agent folder" do
    assert_equal SupportTriageAgent, ManagedAgents.agent("support_triage")
    assert_equal SupportTriageAgent, ManagedAgents.agent("support-triage")
  end

  test "an agent without a Ruby class gets one based on ApplicationAgent" do
    with_agents(agent_files("helper"))
    agent = ManagedAgents.agent("helper")

    assert_operator agent, :<, ApplicationAgent
    assert_equal "helper", agent.agent_name
    assert_equal "Helper", agent.definition.agent_body["name"]
  end

  test "start creates a pinned session with the agent's environment and vault" do
    ticket = Ticket.create!(subject: "Refund")

    session = SupportTriageAgent.start("Triage this", subject: ticket, title: "Refund", metadata: {ticket_id: ticket.id}, max_cost: 2.5)

    params = anthropic.calls_to(:"sesn.create").sole
    assert_equal({type: "agent", id: resource("support_triage", "agent").remote_id, version: 1}, params[:agent])
    assert_equal resource("support_triage", "environment").remote_id, params[:environment_id]
    assert_equal [resource("support_triage", "vault").remote_id], params[:vault_ids]
    assert_equal({ticket_id: ticket.id.to_s}, params[:metadata])
    assert_equal({type: "limit", max_list_cost: {amount: "250", currency: "USD"}}, params[:budget])

    assert_equal "Triage this", anthropic.sent_events.sole.dig(:content, 0, :text)
    assert_equal "Triage this", session.events.sole.text, "the first message is in the transcript straight away"
    assert_equal ticket, session.subject
    assert_equal "running", session.status
    assert_equal "support_triage", session.agent_name
    assert_equal 1, session.agent_version
    assert_equal [session], ticket.agent_sessions.to_a
  end

  test "start enqueues a job to follow the session" do
    assert_enqueued_with(job: ManagedAgents::SessionJob) do
      SupportTriageAgent.start("Triage this")
    end
  end

  test "start without a message creates an idle session and no job" do
    assert_no_enqueued_jobs do
      session = SupportTriageAgent.start
      assert_equal "idle", session.status
    end
    assert_empty anthropic.sent_events
  end

  test "start before syncing explains what to run" do
    ManagedAgents::Resource.delete_all

    error = assert_raises(ManagedAgents::NotSynced) { SupportTriageAgent.start("Hi") }
    assert_match "managed_agents:sync", error.message
  end

  test "a tool handler runs with the session's subject and returns JSON" do
    ticket = Ticket.create!(subject: "Refund")
    agent = SupportTriageAgent.new(SupportTriageAgent.start(subject: ticket))

    result = agent.call_tool("set_priority", {"priority" => "high"})

    refute result.error?
    assert_equal({"ok" => true, "priority" => "high"}, JSON.parse(result.text))
    assert_equal "high", ticket.reload.priority
  end

  test "input that does not match the schema in agent.md never reaches the handler" do
    ticket = Ticket.create!(subject: "Refund")
    agent = SupportTriageAgent.new(SupportTriageAgent.start(subject: ticket))

    result = agent.call_tool("set_priority", {"priority" => "urgent"})

    assert result.error?
    assert_match "input.priority must be one of low, normal, high", result.text
    assert_nil ticket.reload.priority
  end

  test "ToolError becomes an error result for the agent" do
    agent = SupportTriageAgent.new(SupportTriageAgent.start)

    result = agent.call_tool("set_priority", {"priority" => "low"})

    assert result.error?
    assert_equal "There is no ticket to update", result.text
  end

  test "an unexpected exception is reported and returned as an error result" do
    agent_class = Class.new(ApplicationAgent) do
      self.agent_name = "support_triage"
      tool(:set_priority) { |_input| raise "boom" }
    end
    reported = []
    subscriber = Class.new { define_method(:report) { |error, **| reported << error } }.new
    Rails.error.subscribe(subscriber)

    result = agent_class.new(SupportTriageAgent.start).call_tool("set_priority", {"priority" => "low"})

    assert result.error?
    assert_match "set_priority failed: RuntimeError: boom", result.text
    assert_equal ["boom"], reported.map(&:message)
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  test "an unknown tool is an error result" do
    result = SupportTriageAgent.new(SupportTriageAgent.start).call_tool("delete_everything", {})
    assert result.error?
  end

  test "tool handlers are inherited without leaking between subclasses" do
    child = Class.new(SupportTriageAgent) { tool(:extra) { |_| "ok" } }

    assert_equal %w[extra set_priority], child.tools.keys.sort
    assert_equal %w[set_priority], SupportTriageAgent.tools.keys
  end
end

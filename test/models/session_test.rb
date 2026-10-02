require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    sync
    @session = SupportTriageAgent.start
  end

  test "record stores an event once" do
    event = agent_message("Hello")

    assert_instance_of ManagedAgents::Event, @session.record(event)
    assert_nil @session.record(event)
    assert_equal 1, @session.events.count
    assert_equal "Hello", @session.last_agent_message
  end

  test "a queued user message is updated when it is processed" do
    queued = user_message("Hi").merge(processed_at: nil)
    @session.record(queued)
    assert_nil @session.events.sole.processed_at

    @session.record(queued.merge(processed_at: "2026-10-01T12:00:00Z"))
    assert_equal Time.utc(2026, 10, 1, 12), @session.events.sole.processed_at
  end

  test "status follows the session's status events" do
    @session.record(running)
    assert_equal "running", @session.status

    @session.record(idle("requires_action"))
    assert_equal "requires_action", @session.status

    @session.record(idle)
    assert_equal "idle", @session.status
    assert_equal "end_turn", @session.stop_reason

    @session.record(terminated)
    assert @session.terminated?
  end

  test "settled once the agent finished and nothing was sent since" do
    refute @session.settled?

    @session.record(user_message("Hi"))
    @session.record(running)
    refute @session.settled?

    @session.record(idle)
    assert @session.settled?

    @session.record(user_message("One more thing"))
    refute @session.settled?
  end

  test "a message sent while the agent was busy keeps the session unsettled when the earlier turn ends" do
    @session.record(user_message("First").merge(processed_at: "2026-10-01T12:00:00.100Z"))
    @session.record(running.merge(processed_at: "2026-10-01T12:00:00.200Z"))
    queued = user_message("Second").merge(processed_at: nil)
    @session.record(queued)
    @session.record(idle.merge(processed_at: "2026-10-01T12:00:05.000Z"))

    refute @session.settled?, "the second message is still queued"

    @session.record(queued.merge(processed_at: "2026-10-01T12:00:05.100Z"))
    refute @session.settled?, "the second message was processed after the first turn's idle"

    @session.record(running.merge(processed_at: "2026-10-01T12:00:05.200Z"))
    @session.record(idle.merge(processed_at: "2026-10-01T12:00:09.000Z"))
    assert @session.settled?
  end

  test "idle waiting for a tool result is not settled" do
    @session.record(idle("requires_action"))
    refute @session.settled?
  end

  test "pending tool uses are custom tool calls without a result" do
    call = @session.record(custom_tool_use("set_priority", priority: "high"))
    assert_equal [call], @session.pending_tool_uses

    @session.record(build_event("user.custom_tool_result", custom_tool_use_id: call.remote_id, content: []))
    assert_empty @session.pending_tool_uses
  end

  test "awaiting confirmation when only a person can unblock the session" do
    ask = @session.record(tool_use("bash", {command: "rm -rf tmp"}, permission: "ask"))
    @session.record(idle("requires_action"))

    assert @session.awaiting_confirmation?
    assert_equal [ask], @session.pending_confirmations
  end

  test "send_message delivers the event, records it and follows the session" do
    assert_enqueued_with(job: ManagedAgents::SessionJob) { @session.send_message("Hello") }

    sent = anthropic.sent_events.sole
    assert_equal "user.message", sent[:type]
    assert_equal "Hello", @session.events.sole.text
    assert_equal "running", @session.status
  end

  test "confirm_tool answers with the event ID and an optional reason" do
    ask = @session.record(tool_use("bash", {command: "ls"}, permission: "ask"))

    @session.confirm_tool(ask, allow: false, message: "Not that one")

    sent = anthropic.sent_events.sole
    assert_equal({type: "user.tool_confirmation", tool_use_id: ask.remote_id, result: "deny", deny_message: "Not that one"},
      sent.slice(:type, :tool_use_id, :result, :deny_message))
    assert_empty @session.pending_confirmations
  end

  test "interrupt sends user.interrupt" do
    @session.interrupt!
    assert_equal "user.interrupt", anthropic.sent_events.sole[:type]
  end

  test "usage events update the cost" do
    @session.record(build_event("session.usage", usage: {list_cost: {amount: "125", currency: "USD"}}))
    assert_equal 1.25, @session.list_cost
  end

  test "the console link uses the configured workspace" do
    assert_match "/workspaces/default/sessions/#{@session.remote_id}", @session.console_url

    ManagedAgents.config.workspace_id = "wrkspc_123"
    assert_match "/workspaces/wrkspc_123/sessions/", @session.console_url
  end

  test "only one holder gets the lease until it expires or is released" do
    assert @session.acquire_lease("a", ttl: 60)
    refute @session.acquire_lease("b", ttl: 60)
    assert @session.acquire_lease("a", ttl: 60), "the holder can renew"

    @session.release_lease("a")
    assert @session.acquire_lease("b", ttl: 60)

    travel 2.minutes do
      assert @session.acquire_lease("c", ttl: 60), "an expired lease can be taken over"
    end
  end
end

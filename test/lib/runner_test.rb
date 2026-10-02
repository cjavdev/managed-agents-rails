require "test_helper"

class RunnerTest < ActiveSupport::TestCase
  setup do
    sync
    @ticket = Ticket.create!(subject: "Refund not received")
    @session = SupportTriageAgent.start("Triage this ticket", subject: @ticket, run: false)
  end

  def run_session = ManagedAgents::Runner.new(@session).run

  test "follows the stream until the turn ends and stores every event" do
    anthropic.respond_with running, agent_message("Looking at it."), idle

    assert_equal :done, run_session

    assert_equal %w[user.message session.status_running agent.message session.status_idle], @session.events.pluck(:event_type)
    assert_equal "idle", @session.reload.status
    assert_nil @session.lease_token, "the lease is released"
  end

  test "answers a custom tool call with the agent's handler and keeps going" do
    call = custom_tool_use("set_priority", priority: "high", reason: "Customer is waiting on money")
    anthropic.respond_with running, call, idle("requires_action"), agent_message("Set to high."), idle

    assert_equal :done, run_session

    assert_equal "high", @ticket.reload.priority
    result = anthropic.tool_results.sole
    assert_equal call[:id], result[:custom_tool_use_id]
    assert_equal false, result[:is_error]
    assert_equal({"ok" => true, "priority" => "high"}, JSON.parse(result[:content].first[:text]))
  end

  test "runs after_turn callbacks once the turn ends" do
    anthropic.respond_with agent_message("High priority: refund is overdue."), idle

    run_session

    assert_equal "High priority: refund is overdue.", @ticket.reload.summary
  end

  test "a failing tool is answered with an error instead of stalling the session" do
    anthropic.respond_with custom_tool_use("set_priority", priority: "urgent"), agent_message("Sorry."), idle

    run_session

    result = anthropic.tool_results.sole
    assert result[:is_error]
    assert_match "Invalid input", result[:content].first[:text]
  end

  test "a tool call that arrived while nobody was listening is answered from the event history" do
    call = custom_tool_use("set_priority", priority: "low")
    anthropic.history(@session.remote_id).push(running, call, idle("requires_action"))
    anthropic.respond_with agent_message("Done."), idle

    assert_equal :done, run_session

    assert_equal "low", @ticket.reload.priority
    assert_equal call[:id], anthropic.tool_results.sole[:custom_tool_use_id]
  end

  test "a tool call that was already answered is not answered again" do
    call = custom_tool_use("set_priority", priority: "low")
    answer = build_event("user.custom_tool_result", custom_tool_use_id: call[:id], content: [{type: "text", text: "{}"}])
    anthropic.history(@session.remote_id).push(call, answer, agent_message("Done."), idle)

    assert_equal :done, run_session

    assert_empty anthropic.tool_results
    assert_nil @ticket.reload.priority
  end

  test "events seen in both the history and the stream are stored once" do
    message = agent_message("Hello")
    anthropic.history(@session.remote_id).push(message)
    anthropic.respond_with message, idle

    run_session

    assert_equal 1, @session.events.where(event_type: "agent.message").count
  end

  test "stops when a tool call needs a person to approve it" do
    anthropic.respond_with tool_use("bash", {command: "rm -rf /"}, permission: "ask"), idle("requires_action")

    assert_equal :done, run_session

    assert @session.reload.requires_action?
    assert @session.awaiting_confirmation?
  end

  test "returns straight away when the session is already settled" do
    anthropic.history(@session.remote_id).push(agent_message("Done."), idle)
    anthropic.respond_with agent_message("This would only arrive on a new turn")

    assert_equal :done, run_session
    assert_equal 1, @session.events.where(event_type: "agent.message").count
  end

  test "reconnects after a dropped connection without losing or repeating events" do
    dropped = ManagedAgents::Testing.api_error(Anthropic::Errors::APIConnectionError, nil, "connection reset")
    anthropic.respond_with running, dropped, agent_message("Back."), idle

    assert_equal :done, run_session

    assert_equal ["Back."], @session.events.where(event_type: "agent.message").map(&:text)
  end

  test "gives up when the stream keeps closing with nothing new, instead of reconnecting forever" do
    anthropic.respond_with running

    assert_equal :stalled, run_session
    assert_nil @session.reload.lease_token
  end

  test "a stream window that times out is reopened" do
    timeout = ManagedAgents::Testing.api_error(Anthropic::Errors::APITimeoutError, nil, "timed out")
    anthropic.respond_with running, timeout, agent_message("Still here."), idle

    assert_equal :done, run_session
    assert @session.reload.settled?
  end

  test "hands over to a new job when the time limit runs out mid-turn" do
    ManagedAgents.config.max_run_time = -1
    anthropic.respond_with running

    assert_equal :continue, run_session
  end

  test "is busy while another runner holds the lease" do
    @session.acquire_lease("someone-else", ttl: 60)

    assert_equal :busy, run_session
    assert_empty anthropic.calls_to(:"sesn.events.send").drop(1), "nothing was sent beyond the first message"
    assert_equal %w[user.message], @session.events.pluck(:event_type)
  end

  test "session errors reach the agent's on_error callbacks" do
    seen = []
    agent_class = Class.new(SupportTriageAgent) { on_error { |event| seen << event.error_message } }
    stub_method(ManagedAgents::Agent, :for, ->(_name) { agent_class }) do
      anthropic.respond_with session_error("MCP server refused the token"), idle("retries_exhausted")
      run_session
    end

    assert_equal ["MCP server refused the token"], seen
  end

  test "partial text is broadcast as a preview and not stored" do
    previews = []
    stub_method(ManagedAgents::Broadcasts, :preview, ->(_session, text) { previews << text }) do
      ManagedAgents::Runner.send(:remove_const, :PREVIEW_INTERVAL)
      ManagedAgents::Runner.const_set(:PREVIEW_INTERVAL, 0)
      message = agent_message("Hello there")
      anthropic.respond_with(
        {type: "event_start", event: {type: "agent.message", id: message[:id]}},
        {type: "event_delta", event_id: message[:id], delta: {type: "content_delta", index: 0, content: {type: "text", text: "Hello"}}},
        {type: "event_delta", event_id: message[:id], delta: {type: "content_delta", index: 0, content: {type: "text", text: " there"}}},
        message, idle
      )
      run_session
    end

    assert_equal ["Hello", "Hello there", ""], previews, "the stored message clears the preview"
    assert_equal %w[user.message agent.message session.status_idle], @session.events.pluck(:event_type)
  ensure
    ManagedAgents::Runner.send(:remove_const, :PREVIEW_INTERVAL)
    ManagedAgents::Runner.const_set(:PREVIEW_INTERVAL, 0.15)
  end
end

require "test_helper"

class RunnerLimitsTest < ActiveSupport::TestCase
  ATTRIBUTES = %i[event_callbacks interrupt_callbacks max_turn_duration archive_after_turn tools validate_tool_input].freeze

  setup do
    @saved = ATTRIBUTES.to_h { |name| [name, SupportTriageAgent.public_send(name)] }
    sync
    @ticket = Ticket.create!(subject: "Refund not received")
    @session = SupportTriageAgent.start("Triage this ticket", subject: @ticket, run: false)
  end

  teardown do
    @saved.each { |name, value| SupportTriageAgent.public_send(:"#{name}=", value) }
  end

  def run_session = ManagedAgents::Runner.new(@session).run

  def interrupts = anthropic.sent_events.select { |event| event[:type] == "user.interrupt" }

  test "on_event sees every event the runner reads once, before a tool call is answered" do
    seen = []
    client = anthropic
    SupportTriageAgent.on_event { |event| seen << [event.event_type, client.tool_results.size] }
    call = custom_tool_use("set_priority", priority: "high")
    started = running
    anthropic.history(@session.remote_id).push(started)
    anthropic.respond_with started, call, idle("requires_action"), agent_message("Done."), idle

    run_session

    assert_equal [
      ["session.status_running", 0], ["agent.custom_tool_use", 0],
      ["session.status_idle", 1], ["agent.message", 1], ["session.status_idle", 1]
    ], seen
  end

  test "on_event can be narrowed to event types" do
    seen = []
    SupportTriageAgent.on_event("agent.message") { |event| seen << event.text }
    anthropic.respond_with running, agent_message("One."), agent_message("Two."), idle

    run_session

    assert_equal ["One.", "Two."], seen
  end

  test "an on_event callback can interrupt the turn, once" do
    reasons = []
    SupportTriageAgent.on_event("agent.message") { |_event| interrupt!(:budget) }
    SupportTriageAgent.on_interrupt { |reason| reasons << reason }
    anthropic.respond_with agent_message("Spending."), agent_message("Still spending."), idle

    assert_equal :done, run_session

    assert_equal 1, interrupts.size
    assert_equal [:budget], reasons
    assert_empty enqueued_jobs, "interrupting from the runner does not enqueue another job"
  end

  test "a turn past max_turn_duration is interrupted and followed to its end" do
    reasons = []
    SupportTriageAgent.max_turn_duration = 10.minutes
    SupportTriageAgent.on_interrupt { |reason| reasons << reason }
    anthropic.respond_with agent_message("Stopping."), idle

    travel 11.minutes do
      assert_equal :done, run_session
    end

    assert_equal 1, interrupts.size
    assert_equal [:deadline], reasons
    assert_equal "idle", @session.reload.status
  end

  test "a turn inside its limit is left alone, and the stream is held no longer than the time left" do
    SupportTriageAgent.max_turn_duration = -> { 2.minutes }
    timeouts = []
    events = anthropic.beta.sessions.events
    original = events.method(:stream_events)
    events.define_singleton_method(:stream_events) do |id, **params|
      timeouts << params.dig(:request_options, :timeout)
      original.call(id, **params)
    end
    anthropic.respond_with agent_message("Quick."), idle

    run_session

    assert_empty interrupts
    assert_includes 100..120, timeouts.sole
  end

  test "archive_after_turn archives the session once the turn ends" do
    SupportTriageAgent.archive_after_turn = true
    anthropic.respond_with agent_message("Done."), idle

    run_session

    assert_equal [@session.remote_id], anthropic.calls_to(:"sesn.archive").map { |call| call[:id] }
    assert @session.reload.archived_at
  end

  test "sessions are not archived by default" do
    anthropic.respond_with agent_message("Done."), idle

    run_session

    assert_empty anthropic.calls_to(:"sesn.archive")
    assert_nil @session.reload.archived_at
  end

  test "a handler can read the ID of the call it is answering" do
    ids = []
    SupportTriageAgent.tool(:set_priority) { |_input| ids << tool_use_id }
    call = custom_tool_use("set_priority", priority: "high")
    anthropic.respond_with call, idle("requires_action"), agent_message("Done."), idle

    run_session

    assert_equal [call[:id]], ids
  end

  test "validate_tool_input false hands bad input to the handler" do
    SupportTriageAgent.validate_tool_input = false
    SupportTriageAgent.tool(:set_priority) { |input| ManagedAgents::Tool.error("my own words: #{input[:priority]}") }
    anthropic.respond_with custom_tool_use("set_priority", priority: "urgent"), agent_message("Sorry."), idle

    run_session

    assert_equal "my own words: urgent", anthropic.tool_results.sole[:content].first[:text]
  end
end

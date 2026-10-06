require "test_helper"

class AttachTest < ActiveSupport::TestCase
  setup do
    sync
    @ticket = Ticket.create!(subject: "Refund not received")
  end

  # A session another process started: on the API, not in this database.
  def remote_session(status: "running")
    anthropic.beta.sessions.store(ManagedAgents::Testing::Record.new(
      id: "sesn_elsewhere", status: status, title: "Started elsewhere", metadata: {ticket_id: "7"},
      agent: {type: "agent", id: resource("support_triage", "agent").remote_id, version: 1}, archived_at: nil
    ))
  end

  test "attach gives an existing session a record, once" do
    remote_session

    session = SupportTriageAgent.attach("sesn_elsewhere", subject: @ticket)

    assert_equal ["sesn_elsewhere", "support_triage", 1, "Started elsewhere", {"ticket_id" => "7"}, @ticket],
      session.values_at(:remote_id, :agent_name, :agent_version, :title, :metadata, :subject)
    assert_equal session, SupportTriageAgent.attach("sesn_elsewhere", subject: @ticket)
    assert_equal 1, ManagedAgents::Session.count
  end

  test "an attached session's log is replayed and its tool calls answered" do
    remote_session
    call = custom_tool_use("set_priority", priority: "high")
    anthropic.history("sesn_elsewhere").push(user_message("Triage this"), call, idle("requires_action"))
    anthropic.respond_with agent_message("Done."), idle

    session = SupportTriageAgent.attach("sesn_elsewhere", subject: @ticket)
    assert_equal :done, session.run_now

    assert_equal "high", @ticket.reload.priority
    assert_equal call[:id], anthropic.tool_results.sole[:custom_tool_use_id]
  end

  test "a session with nothing recorded yet is followed while the API says it is working" do
    remote_session(status: "running")
    anthropic.respond_with agent_message("Still here."), idle

    session = SupportTriageAgent.attach("sesn_elsewhere")
    assert_equal :done, session.run_now

    assert_equal "Still here.", session.last_agent_message
  end

  test "a session with nothing recorded and idle on the API is done" do
    remote_session(status: "idle")

    assert_equal :done, SupportTriageAgent.attach("sesn_elsewhere").run_now
    assert_empty ManagedAgents::Event.all
  end
end

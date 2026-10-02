require "test_helper"
require "turbo/broadcastable/test_helper"

class ChatTest < ActionDispatch::IntegrationTest
  include Turbo::Broadcastable::TestHelper

  setup do
    sync
    @session = SupportTriageAgent.start("Triage this ticket", title: "Refund", run: false)
  end

  test "the index lists sessions and offers every agent" do
    get agent_sessions_path

    assert_response :success
    assert_select ".ma-session-list__item a", text: "Refund"
    assert_select "select[name=agent] option[value=support_triage]"
  end

  test "starting a session from the form redirects to it" do
    post agent_sessions_path, params: {agent: "support_triage", message: "Look at ticket 12"}

    session = ManagedAgents::Session.order(:id).last
    assert_redirected_to agent_session_path(session)
    assert_equal "Look at ticket 12", session.title
    assert_enqueued_jobs 1, only: ManagedAgents::SessionJob
  end

  test "starting a session for an agent that is not synced shows the reason" do
    ManagedAgents::Resource.delete_all

    post agent_sessions_path, params: {agent: "support_triage", message: "Hi"}

    assert_redirected_to agent_sessions_path
    assert_match "managed_agents:sync", flash[:alert]
  end

  test "the transcript shows messages, tool calls and results" do
    @session.record(user_message("Triage this ticket"))
    call = @session.record(custom_tool_use("set_priority", priority: "high"))
    @session.record(build_event("user.custom_tool_result", custom_tool_use_id: call.remote_id, content: [{type: "text", text: '{"ok":true}'}]))
    @session.record(agent_message("Set to **high**."))
    @session.record(idle)

    get agent_session_path(@session)

    assert_response :success
    assert_select "##{@session.events_dom_id} .ma-bubble--user", text: /Triage this ticket/
    assert_select ".ma-tool code", text: "set_priority"
    assert_select ".ma-tool pre", text: /"priority": "high"/
    assert_select ".ma-tool--result pre", text: /"ok":true/
    assert_select ".ma-bubble--agent", text: /Set to \*\*high\*\*\./
    assert_select "##{@session.status_dom_id}", text: /Idle/
    assert_select "turbo-cable-stream-source"
    assert_select "form.ma-composer textarea[name=message]"
  end

  test "agent text is escaped" do
    @session.record(agent_message("<script>alert(1)</script> done"))

    get agent_session_path(@session)

    assert_select ".ma-bubble--agent script", count: 0
    assert_match "done", response.body
  end

  test "a configured Markdown renderer is used for agent messages" do
    ManagedAgents.config.markdown = ->(text) { "<strong class=\"rendered\">#{ERB::Util.html_escape(text)}</strong>" }
    @session.record(agent_message("Hello"))

    get agent_session_path(@session)

    assert_select ".ma-bubble--agent strong.rendered", text: "Hello"
  end

  test "sending a message delivers it and follows the session" do
    assert_enqueued_with(job: ManagedAgents::SessionJob) do
      post agent_session_messages_path(@session), params: {message: "Any update?"}, as: :turbo_stream
    end

    assert_response :no_content
    assert_equal "Any update?", anthropic.sent_events.last.dig(:content, 0, :text)
  end

  test "a tool call waiting for approval shows Allow and Deny, and Allow confirms it" do
    ask = @session.record(tool_use("bash", {command: "bin/rails db:reset"}, permission: "ask"))
    @session.record(idle("requires_action"))

    get agent_session_path(@session)
    assert_select ".ma-confirm form[action='#{agent_session_confirmations_path(@session)}']", count: 2

    post agent_session_confirmations_path(@session), params: {event_id: ask.id, result: "allow"}

    assert_redirected_to agent_session_path(@session)
    confirmation = anthropic.sent_events.last
    assert_equal [ask.remote_id, "allow"], confirmation.values_at(:tool_use_id, :result)

    get agent_session_path(@session)
    assert_select ".ma-confirm", count: 0
  end

  test "Stop interrupts the session" do
    post agent_session_interrupt_path(@session)

    assert_redirected_to agent_session_path(@session)
    assert_equal "user.interrupt", anthropic.sent_events.last[:type]
  end

  test "new events are broadcast to the session's stream" do
    streams = capture_turbo_stream_broadcasts(@session) do
      @session.record(agent_message("Hello from the agent"))
    end

    append = streams.find { |stream| stream["action"] == "append" }
    assert_equal @session.events_dom_id, append["target"]
    assert_match "Hello from the agent", append.to_html
    assert streams.any? { |stream| stream["action"] == "update" && stream["target"] == @session.preview_dom_id }, "the preview is cleared"
  end

  test "status changes are broadcast" do
    streams = capture_turbo_stream_broadcasts(@session) { @session.record(idle) }

    replace = streams.find { |stream| stream["action"] == "replace" }
    assert_equal @session.status_dom_id, replace["target"]
    assert_match "Idle", replace.to_html
  end

  test "events that have no visual form are stored but not broadcast" do
    quiet = SupportTriageAgent.start

    assert_no_turbo_stream_broadcasts(quiet) do
      assert quiet.record(build_event("span.model_request_start"))
    end
  end

  test "broadcasting can be switched off" do
    ManagedAgents.config.broadcast = false
    quiet = SupportTriageAgent.start

    assert_no_turbo_stream_broadcasts(quiet) { quiet.record(agent_message("Quiet")) }
  end
end

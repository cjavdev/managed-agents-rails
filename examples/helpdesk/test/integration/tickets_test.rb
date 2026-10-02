require "test_helper"

class TicketsTest < ActionDispatch::IntegrationTest
  setup { sync_agents }

  def create_ticket
    post tickets_path, params: {ticket: {customer_email: "dana@example.com", subject: "Charged twice", body: "Two charges on Oct 1."}}
    Ticket.order(:id).last
  end

  test "creating a ticket saves it and starts triage" do
    ticket = nil
    assert_enqueued_with(job: ManagedAgents::SessionJob) { ticket = create_ticket }

    assert_redirected_to ticket
    assert_equal ticket, ManagedAgents::Session.sole.subject
  end

  test "a ticket is still saved when triage cannot start" do
    ManagedAgents::Resource.delete_all

    ticket = create_ticket
    follow_redirect!

    assert ticket.persisted?
    assert_select ".ma-note--error", text: /triage did not start/
    assert_select ".triage", text: /Waiting for the agent/
  end

  test "an invalid ticket re-renders the form" do
    post tickets_path, params: {ticket: {customer_email: "", subject: "", body: ""}}

    assert_response :unprocessable_entity
    assert_select ".ma-note--error"
  end

  test "after the agent's turn the ticket shows the triage and the activity" do
    anthropic.respond_with(
      custom_tool_use("classify_ticket", priority: "high", category: "billing", team: "billing", summary: "Double charge on Oct 1."),
      custom_tool_use("draft_reply", body: "Hi Dana, I can see both charges and have refunded one."),
      agent_message("Classified as high priority billing and drafted a reply."), idle
    )
    ticket = perform_enqueued_jobs { create_ticket }

    get ticket_path(ticket)

    assert_select ".triage .priority--high", text: "high"
    assert_select ".triage dd", text: "Double charge on Oct 1."
    assert_select ".reply", text: /refunded one/
    assert_select ".activity .ma-tool code", text: "classify_ticket"
    assert_select ".activity .ma-bubble--agent", text: /drafted a reply/
    assert_select ".activity form.ma-composer"
  end

  test "the inbox lists open tickets by urgency and shows the latest digest" do
    Ticket.create!(customer_email: "a@example.com", subject: "Export question", body: "How?", priority: "low")
    Ticket.create!(customer_email: "b@example.com", subject: "Site down", body: "Nothing loads.", priority: "urgent")
    DailyDigest.create!(body: "One outage report needs engineering now.")

    get tickets_path

    assert_select ".tickets li a" do |links|
      assert_equal ["Site down", "Export question"], links.map(&:text)
    end
    assert_select ".digest", text: /One outage report/
  end

  test "triage can be run again in a new session" do
    ticket = create_ticket

    assert_difference -> { ticket.agent_sessions.count }, 1 do
      post ticket_triage_path(ticket)
    end
    assert_redirected_to ticket
  end

  test "writing the digest now fires the deployment and opens its session" do
    post digest_path

    session = ManagedAgents::Session.sole
    assert_redirected_to agent_session_path(session)
    assert_equal "daily", session.deployment_key
  end

  test "closing a ticket takes it out of the inbox" do
    ticket = create_ticket

    patch ticket_path(ticket), params: {ticket: {status: "closed"}}
    get tickets_path

    assert_select ".tickets li", count: 0
  end
end

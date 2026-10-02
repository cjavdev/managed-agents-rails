require "test_helper"

class TicketTriageAgentTest < ActiveSupport::TestCase
  setup do
    sync_agents
    @ticket = Ticket.create!(customer_email: "sam@example.com", subject: "Can't log in", body: "Login fails after a password reset.")
  end

  def triage(*events)
    anthropic.respond_with(*events)
    perform_enqueued_jobs { @ticket.triage }
    @ticket.reload
  end

  test "the definition and the handlers agree" do
    assert_empty ManagedAgents::Sync.new(io: StringIO.new).problems
  end

  test "sync creates the agent, its environment, an empty vault and the digest deployment" do
    assert_equal %w[agent deployment environment vault], ManagedAgents::Resource.pluck(:kind).sort
    assert_equal "0 8 * * 1-5", anthropic.calls_to(:"depl.create").sole.dig(:schedule, :expression)
  end

  test "classify_ticket records the triage decision" do
    triage custom_tool_use("classify_ticket", priority: "urgent", category: "account", team: "engineering",
      summary: "Whole team locked out after a password reset, launch tomorrow."), idle

    assert_equal %w[urgent account engineering], @ticket.values_at(:priority, :category, :team)
    assert_match "locked out", @ticket.summary
  end

  test "a priority outside the allowed values is refused" do
    triage custom_tool_use("classify_ticket", priority: "critical", category: "account", team: "engineering", summary: "x"), idle

    assert anthropic.tool_results.sole[:is_error]
    assert_nil @ticket.priority
  end

  test "draft_reply saves a suggestion without sending anything" do
    triage custom_tool_use("draft_reply", body: "Hi Sam, sorry about this. We're looking at it now."), idle

    assert_match "Hi Sam", @ticket.suggested_reply
  end

  test "find_similar_tickets returns earlier tickets but not the one being triaged" do
    earlier = Ticket.create!(customer_email: "kim@example.com", subject: "Login broken", body: "Password reset then invalid session.", priority: "high")

    triage custom_tool_use("find_similar_tickets", query: "password reset"), idle

    found = JSON.parse(anthropic.tool_results.sole[:content].first[:text])
    assert_equal [earlier.id], found.map { |ticket| ticket["id"] }
    assert_equal "high", found.first["priority"]
  end

  test "the daily deployment writes a digest in a session with no ticket" do
    anthropic.respond_with custom_tool_use("list_open_tickets"),
      custom_tool_use("save_digest", body: "One open ticket: a login failure that needs engineering."),
      agent_message("Digest saved."), idle

    perform_enqueued_jobs { TicketTriageAgent.run_deployment(:daily) }

    assert_equal "One open ticket: a login failure that needs engineering.", DailyDigest.latest.body
    listed = JSON.parse(anthropic.tool_results.first[:content].first[:text])
    assert_equal ["Can't log in"], listed.map { |ticket| ticket["subject"] }
  end

  test "ticket tools explain themselves when the session has no ticket" do
    anthropic.respond_with custom_tool_use("draft_reply", body: "Hello"), idle

    perform_enqueued_jobs { TicketTriageAgent.run_deployment(:daily) }

    result = anthropic.tool_results.sole
    assert result[:is_error]
    assert_equal "This session is not about a single ticket", result[:content].first[:text]
  end
end

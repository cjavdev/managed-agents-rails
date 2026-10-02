# Ruby side of app/agents/ticket_triage/. A triage session's subject is the
# ticket; a digest session has no subject.
class TicketTriageAgent < ApplicationAgent
  tool :classify_ticket do |input|
    ticket.update!(input.slice(:priority, :category, :team, :summary))
    {ok: true}
  end

  tool :draft_reply do |input|
    ticket.update!(suggested_reply: input[:body])
    {ok: true}
  end

  tool :find_similar_tickets do |input|
    Ticket.where.not(id: subject&.id).matching(input[:query]).limit(5).map { |ticket| describe(ticket) }
  end

  tool :list_open_tickets do |_input|
    Ticket.open.by_urgency.map { |ticket| describe(ticket) }
  end

  tool :save_digest do |input|
    DailyDigest.create!(body: input[:body])
    {ok: true}
  end

  private

  def ticket
    subject || raise(ManagedAgents::ToolError, "This session is not about a single ticket")
  end

  def describe(ticket)
    ticket.slice(:id, :subject, :status, :priority, :category, :team, :summary).merge(received: ticket.created_at.to_date)
  end
end

# Runs triage again in a fresh session.
class Tickets::TriagesController < ApplicationController
  def create
    ticket = Ticket.find(params[:ticket_id])
    ticket.triage
    redirect_to ticket
  rescue ManagedAgents::Error, Anthropic::Errors::Error => error
    redirect_to ticket, alert: error.message
  end
end

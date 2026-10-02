class TicketsController < ApplicationController
  def index
    @tickets = Ticket.open.by_urgency
    @digest = DailyDigest.latest
  end

  def show
    @ticket = Ticket.find(params[:id])
    @session = @ticket.triage_session
  end

  def new
    @ticket = Ticket.new
  end

  def create
    @ticket = Ticket.new(params.expect(ticket: [:customer_email, :subject, :body]))

    if @ticket.save
      start_triage(@ticket)
      redirect_to @ticket
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    ticket = Ticket.find(params[:id])
    ticket.update!(params.expect(ticket: [:status]))
    redirect_to ticket
  end

  private

  # A ticket is still saved when the agent can't be reached.
  def start_triage(ticket)
    ticket.triage
  rescue ManagedAgents::Error, Anthropic::Errors::Error => error
    flash[:alert] = "Saved, but triage did not start: #{error.message}"
  end
end

# Fires the daily digest deployment now instead of waiting for its schedule.
class DigestsController < ApplicationController
  def create
    agent_session = TicketTriageAgent.run_deployment(:daily)
    redirect_to agent_session_path(agent_session)
  rescue ManagedAgents::Error, Anthropic::Errors::Error => error
    redirect_to tickets_path, alert: error.message
  end
end

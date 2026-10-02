class AgentSessions::InterruptsController < ApplicationController
  def create
    agent_session = ManagedAgents::Session.find(params[:agent_session_id])
    agent_session.interrupt!

    redirect_to agent_session_path(agent_session)
  end
end

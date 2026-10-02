class AgentSessions::InterruptsController < ApplicationController
  include AgentAccess

  def create
    agent_session = agent_sessions.find(params[:agent_session_id])
    agent_session.interrupt!

    redirect_to agent_session_path(agent_session)
  end
end

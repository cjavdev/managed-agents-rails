# Allows or denies a tool call that paused for approval.
class AgentSessions::ConfirmationsController < ApplicationController
  include AgentAccess

  def create
    agent_session = agent_sessions.find(params[:agent_session_id])
    event = agent_session.events.find(params[:event_id])
    agent_session.confirm_tool(event, allow: params[:result] == "allow", message: params[:message])

    redirect_to agent_session_path(agent_session)
  end
end

class AgentSessions::MessagesController < ApplicationController
  def create
    agent_session = ManagedAgents::Session.find(params[:agent_session_id])
    agent_session.send_message(params.require(:message))

    respond_to do |format|
      # The message itself arrives over the Turbo Stream once it is recorded.
      format.turbo_stream { head :no_content }
      format.html { redirect_to agent_session_path(agent_session) }
    end
  rescue Anthropic::Errors::Error => error
    redirect_to agent_session_path(params[:agent_session_id]), alert: error.message
  end
end

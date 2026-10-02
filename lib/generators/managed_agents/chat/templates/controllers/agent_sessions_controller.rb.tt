class AgentSessionsController < ApplicationController
  # Anyone who can reach these actions can talk to your agents and see every
  # session. Put your own authentication here before deploying.
  # before_action :authenticate_user!

  def index
    @sessions = ManagedAgents::Session.recent.limit(50)
    @agents = ManagedAgents.definitions
  end

  def show
    @session = ManagedAgents::Session.find(params[:id])
    @events = @session.events
  end

  def create
    agent = ManagedAgents.agent(params.require(:agent))
    agent_session = agent.start(params[:message].presence, title: params[:message].to_s.truncate(60).presence)
    redirect_to agent_session_path(agent_session)
  rescue ManagedAgents::Error, Anthropic::Errors::Error => error
    redirect_to agent_sessions_path, alert: error.message
  end
end

class AgentSessionsController < ApplicationController
  include AgentAccess

  def index
    @sessions = agent_sessions.recent.limit(50)
    @agents = ManagedAgents.definitions
    @missing = @agents.to_h { |agent| [agent.name, ManagedAgents.agent(agent.name).missing_connections(owner: agent_owner)] }
  end

  def show
    @session = agent_sessions.find(params[:id])
    @events = @session.events
  end

  # The session acts with the vaults its agent declares (`vaults` in the agent
  # class). Pass `vaults:` here to choose per session instead, for example
  # `vaults: [agent_owner, :agent]`.
  def create
    agent = ManagedAgents.agent(params.require(:agent))
    agent_session = agent.start(params[:message].presence, owner: agent_owner,
      title: params[:message].to_s.truncate(60).presence)
    redirect_to agent_session_path(agent_session)
  rescue ManagedAgents::Error, Anthropic::Errors::Error => error
    redirect_to agent_sessions_path, alert: error.message
  end
end

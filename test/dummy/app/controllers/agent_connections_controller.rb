# Lets people connect the MCP servers the agents use: their own account under
# "personal", and shared service accounts under "organization".
class AgentConnectionsController < ApplicationController
  include AgentAccess

  rescue_from ManagedAgents::Error, Anthropic::Errors::Error do |error|
    redirect_to agent_connections_path, alert: error.message
  end

  def index
    @servers = ManagedAgents::MCP.servers
    @owners = agent_vault_owners
  end

  # With a token, stores it. Without one, sends the person to the server's
  # authorization page; they come back to #callback.
  def create
    owner = vault_owner(params[:group])

    if params[:token].present?
      ManagedAgents::Vault.for(owner).connect_bearer(server.url, token: params[:token], display_name: server.name.humanize)
      redirect_to agent_connections_path, notice: "#{server.name.humanize} connected."
    else
      pending = ManagedAgents::OAuth.authorize(server.url, redirect_uri: callback_agent_connections_url)
      session[:agent_connection] = pending.to_h.merge("group" => params[:group])
      redirect_to pending.url, allow_other_host: true
    end
  end

  def callback
    pending = session.delete(:agent_connection)
    raise ManagedAgents::OAuth::Rejected, "No connection was in progress" unless pending

    ManagedAgents::OAuth.complete(vault_owner(pending["group"]), pending, params)
    redirect_to agent_connections_path, notice: "Connected."
  end

  def destroy
    vaults = ManagedAgents::Vault.where(owner: agent_vault_owners.values)
    ManagedAgents::Connection.where(vault: vaults).find(params[:id]).destroy!
    redirect_to agent_connections_path, notice: "Disconnected."
  end

  private

  # Only servers an agent declares can be connected.
  def server
    @server ||= ManagedAgents::MCP.server(params[:server_url]) || raise(ActiveRecord::RecordNotFound)
  end

  def vault_owner(group)
    agent_vault_owners.fetch(group.to_s) { raise ActiveRecord::RecordNotFound }
  end
end

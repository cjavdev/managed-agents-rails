require "managed_agents/oauth/http"
require "managed_agents/oauth/discovery"
require "managed_agents/oauth/flow"

module ManagedAgents
  # Gets a person's OAuth tokens for an MCP server and puts them in a vault.
  #
  # Anthropic refreshes tokens once they are in a vault, but obtaining them is
  # the app's job. This follows the MCP authorization flow: discover the
  # server's authorization server, register a client, send the person to
  # authorize with PKCE, and exchange the code.
  #
  #   # start
  #   pending = ManagedAgents::OAuth.authorize(server_url, redirect_uri: callback_url)
  #   session[:agent_connection] = pending.to_h
  #   redirect_to pending.url, allow_other_host: true
  #
  #   # callback
  #   ManagedAgents::OAuth.complete(current_user, session.delete(:agent_connection), params)
  module OAuth
    class Error < ManagedAgents::Error; end

    # The authorization server sent the person back with an error, or the
    # callback doesn't belong to a flow this browser started.
    class Rejected < Error; end

    module_function

    def authorize(server_url, redirect_uri:)
      Flow.new(server_url, redirect_uri: redirect_uri).authorization_request
    end

    def complete(vault, pending, params)
      pending = pending.to_h.with_indifferent_access
      raise Rejected, "No connection was in progress" if pending[:state].blank?
      unless ActiveSupport::SecurityUtils.secure_compare(pending[:state].to_s, params[:state].to_s)
        raise Rejected, "The authorization response does not match the request that was started"
      end
      if params[:error].present?
        raise Rejected, params[:error_description].presence || "Authorization was not granted (#{params[:error]})"
      end

      # Given an owner rather than a vault, the vault is only created once the
      # response has been checked.
      vault = Vault.for(vault) unless vault.is_a?(Vault)
      Flow.new(pending[:server_url], redirect_uri: pending[:redirect_uri])
        .connect(vault, code: params[:code], code_verifier: pending[:code_verifier])
    end
  end
end

require "securerandom"
require "digest"

module ManagedAgents
  module OAuth
    # One authorization-code flow with PKCE against an MCP server's
    # authorization server.
    class Flow
      # What has to survive between sending the person away and their return.
      # Keep it in the session: the code verifier must not leave the server.
      Request = Struct.new(:url, :state, :code_verifier, :server_url, :redirect_uri, :scope, keyword_init: true) do
        def to_h = super.except(:url).compact.stringify_keys
      end

      Tokens = Struct.new(:access_token, :refresh_token, :expires_at, :scope, keyword_init: true)

      attr_reader :server_url, :redirect_uri

      # `scope` overrides the scopes the server advertises.
      def initialize(server_url, redirect_uri:, scope: nil)
        @server_url = server_url
        @redirect_uri = redirect_uri
        @scope = scope.presence
      end

      def scope = @scope || client.scope

      def authorization_request
        state = SecureRandom.urlsafe_base64(32)
        verifier = SecureRandom.urlsafe_base64(64)
        query = {
          response_type: "code",
          client_id: client.client_id,
          redirect_uri: redirect_uri,
          state: state,
          code_challenge: [Digest::SHA256.digest(verifier)].pack("m0").tr("+/", "-_").delete("="),
          code_challenge_method: "S256",
          scope: scope,
          resource: server_url
        }.compact

        endpoint = URI.parse(client.endpoints.fetch("authorization_endpoint"))
        endpoint.query = [endpoint.query, URI.encode_www_form(query)].compact.join("&")
        Request.new(url: endpoint.to_s, state: state, code_verifier: verifier, server_url: server_url, redirect_uri: redirect_uri,
          scope: @scope)
      end

      def exchange(code:, code_verifier:)
        raise Rejected, "The authorization response had no code" if code.blank?

        params = {grant_type: "authorization_code", code: code, redirect_uri: redirect_uri,
                  code_verifier: code_verifier, resource: server_url}
        basic = nil
        case client.auth_method
        when "client_secret_basic" then basic = [client.client_id, client.client_secret]
        when "client_secret_post" then params.update(client_id: client.client_id, client_secret: client.client_secret)
        else params[:client_id] = client.client_id
        end

        response = HTTP.post_form(client.endpoints.fetch("token_endpoint"), params, basic_auth: basic)
        body = response.json
        unless response.ok? && body["access_token"].present?
          raise Error, "The token request failed: #{body["error_description"] || body["error"] || "HTTP #{response.status}"}"
        end

        Tokens.new(access_token: body["access_token"], refresh_token: body["refresh_token"], scope: body["scope"] || scope,
          expires_at: body["expires_in"] && Time.current + body["expires_in"].to_i)
      end

      # Exchanges the code and stores the result in the vault.
      def connect(vault, code:, code_verifier:)
        tokens = exchange(code: code, code_verifier: code_verifier)
        vault.connect_oauth(server_url,
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_at: tokens.expires_at,
          token_endpoint: client.endpoints.fetch("token_endpoint"),
          client_id: client.client_id,
          client_secret: client.client_secret,
          client_auth: (client.auth_method unless client.auth_method == "none"),
          scope: tokens.scope,
          resource: server_url,
          display_name: MCP.server(server_url)&.name&.humanize)
      end

      private

      def client
        @client ||= OAuthClient.for(server_url, redirect_uri: redirect_uri)
      end
    end
  end
end

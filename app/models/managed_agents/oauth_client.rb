module ManagedAgents
  # The OAuth client this app is to one MCP server's authorization server.
  # Registered once per server and callback URL (dynamic client registration,
  # RFC 7591) and reused for everyone who connects. Servers that don't offer
  # registration need a client in the configuration instead:
  #
  #   config.oauth_clients = {
  #     "https://mcp.slack.com/mcp" => {client_id: "...", client_secret: "...", scope: "channels:read"}
  #   }
  class OAuthClient < ApplicationRecord
    # A client taken from configuration rather than registered.
    Configured = Struct.new(:client_id, :client_secret, :auth_method, :scope, :endpoints, keyword_init: true)

    self.table_name = "managed_agents_oauth_clients"

    validates :server_url, :redirect_uri, :client_id, presence: true

    def self.for(server_url, redirect_uri:)
      key = MCP.normalize(server_url)
      configured(key) || find_by(server_url: key, redirect_uri: redirect_uri) || register(server_url, key, redirect_uri)
    end

    def self.configured(key)
      settings = ManagedAgents.config.oauth_clients.transform_keys { |url| MCP.normalize(url) }[key] or return
      settings = settings.to_h.symbolize_keys
      discovered = OAuth::Discovery.new(key).metadata

      Configured.new(
        client_id: settings.fetch(:client_id),
        client_secret: settings[:client_secret],
        auth_method: (settings[:auth_method] || (settings[:client_secret] ? "client_secret_post" : "none")).to_s,
        scope: settings[:scope] || discovered.scopes&.join(" "),
        endpoints: discovered.to_h.merge(settings.slice(:authorization_endpoint, :token_endpoint).stringify_keys)
      )
    end

    def self.register(server_url, key, redirect_uri)
      discovered = OAuth::Discovery.new(server_url).metadata
      if discovered.registration_endpoint.blank?
        raise OAuth::Error, "#{server_url} does not offer client registration. Add a client for it to config.oauth_clients."
      end

      response = OAuth::HTTP.post_json(discovered.registration_endpoint,
        client_name: ManagedAgents.config.oauth_client_name,
        redirect_uris: [redirect_uri],
        grant_types: %w[authorization_code refresh_token],
        response_types: ["code"],
        token_endpoint_auth_method: "none")
      body = response.json
      raise OAuth::Error, "Client registration with #{server_url} failed (HTTP #{response.status})" unless response.ok? && body["client_id"].present?

      create!(server_url: key, redirect_uri: redirect_uri, client_id: body["client_id"], client_secret: body["client_secret"],
        metadata: discovered.to_h.merge("auth_method" => body["token_endpoint_auth_method"] || (body["client_secret"] ? "client_secret_basic" : "none")))
    rescue ActiveRecord::RecordNotUnique
      find_by!(server_url: key, redirect_uri: redirect_uri)
    end

    def endpoints = metadata

    def auth_method = metadata["auth_method"]

    def scope
      Array(metadata["scopes"]).join(" ").presence
    end
  end
end

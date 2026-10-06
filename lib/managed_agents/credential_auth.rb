module ManagedAgents
  # Shapes of a vault credential's `auth` hash.
  module CredentialAuth
    IMMUTABLE = %w[mcp_server_url secret_name].freeze
    # `resource` is not among the fields a credential update accepts.
    IMMUTABLE_REFRESH = %w[token_endpoint client_id resource].freeze

    module_function

    # An mcp_oauth `auth` hash. With a refresh token (and the endpoint and
    # client that issued it) Anthropic keeps the access token fresh.
    def mcp_oauth(url, access_token:, refresh_token: nil, expires_at: nil, token_endpoint: nil, client_id: nil,
      client_secret: nil, client_auth: nil, scope: nil, resource: nil)
      auth = {type: "mcp_oauth", mcp_server_url: url, access_token: access_token, expires_at: expires_at&.iso8601}.compact
      if refresh_token
        auth[:refresh] = {
          refresh_token: refresh_token,
          token_endpoint: token_endpoint,
          client_id: client_id,
          scope: scope,
          resource: resource,
          token_endpoint_auth: token_endpoint_auth(client_secret, client_auth)
        }.compact
      end
      auth
    end

    def token_endpoint_auth(client_secret, client_auth)
      return {type: "none"} if client_secret.blank?

      {type: (client_auth || "client_secret_post").to_s, client_secret: client_secret}
    end

    # What a credential is unique by inside a vault.
    def key(auth)
      auth = auth.to_h.stringify_keys
      auth["secret_name"] || (auth["mcp_server_url"] && MCP.normalize(auth["mcp_server_url"]))
    end

    # The part of `auth` an update may send: the fields a credential is matched
    # on can't change once it exists.
    def mutable(auth)
      auth = auth.deep_stringify_keys.except(*IMMUTABLE)
      auth["refresh"] = auth["refresh"].except(*IMMUTABLE_REFRESH) if auth["refresh"].is_a?(Hash)
      auth
    end

    # The fields that force a credential to be replaced rather than updated.
    def structure(auth)
      auth = auth.deep_stringify_keys
      auth.slice("type", *IMMUTABLE).merge(auth["refresh"].to_h.slice(*IMMUTABLE_REFRESH))
    end
  end
end

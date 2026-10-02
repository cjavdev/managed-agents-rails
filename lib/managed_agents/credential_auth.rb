module ManagedAgents
  # Shapes of a vault credential's `auth` hash.
  module CredentialAuth
    IMMUTABLE = %w[mcp_server_url secret_name].freeze
    # `resource` is not among the fields a credential update accepts.
    IMMUTABLE_REFRESH = %w[token_endpoint client_id resource].freeze

    module_function

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

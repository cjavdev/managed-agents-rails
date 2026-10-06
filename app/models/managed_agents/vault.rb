module ManagedAgents
  # A group of credentials that belongs to one of the app's records: a user's
  # personal connections, or an account's shared service accounts.
  #
  #   vault = ManagedAgents::Vault.for(current_user)
  #   vault.connect_bearer("https://mcp.linear.app/mcp", token: params[:token])
  #   vault.connected?("https://mcp.linear.app/mcp")
  #
  # An owner can have several, by name, to keep groups of service accounts
  # apart: ManagedAgents::Vault.for(account, :billing).
  #
  # Vaults are workspace-wide on the API: any session may attach any vault.
  # Which vaults a session gets is decided here, by ownership.
  class Vault < ApplicationRecord
    DEFAULT = "default"

    belongs_to :owner, polymorphic: true
    has_many :connections, dependent: :destroy

    validates :remote_id, :name, presence: true

    before_destroy :archive_remote

    # The owner's vault, created on the API the first time it is needed.
    def self.for(owner, name = DEFAULT)
      find_by(owner: owner, name: name.to_s) || provision(owner, name.to_s)
    end

    def self.provision(owner, name = DEFAULT)
      remote = ManagedAgents.client.beta.vaults.create(
        display_name: [owner.class.name, owner.id, (name unless name == DEFAULT)].compact.join(" "),
        metadata: {owner: owner.to_gid.to_s, name: name}
      )
      create!(owner: owner, name: name, remote_id: remote.id, workspace_id: ManagedAgents.config.workspace_id)
    rescue ActiveRecord::RecordNotUnique
      # Another request created this vault first; keep theirs.
      ManagedAgents.client.beta.vaults.archive(remote.id)
      find_by!(owner: owner, name: name)
    end

    # A fixed token for an MCP server (API key, personal access token).
    def connect_bearer(url, token:, display_name: nil)
      store({type: "static_bearer", mcp_server_url: url, token: token}, display_name: display_name)
    end

    # OAuth tokens for an MCP server. With a refresh token (and the endpoint
    # and client that issued it) Anthropic keeps the access token fresh.
    def connect_oauth(url, access_token:, refresh_token: nil, expires_at: nil, token_endpoint: nil, client_id: nil,
      client_secret: nil, client_auth: nil, scope: nil, resource: nil, display_name: nil)
      auth = CredentialAuth.mcp_oauth(url, access_token: access_token, refresh_token: refresh_token, expires_at: expires_at,
        token_endpoint: token_endpoint, client_id: client_id, client_secret: client_secret, client_auth: client_auth,
        scope: scope, resource: resource)
      store(auth, display_name: display_name, details: {scope: scope}.compact)
    end

    # A secret exposed to the sandbox as an environment variable placeholder
    # and substituted when a request leaves for one of the allowed hosts.
    def connect_env(name, value:, allowed_hosts: nil, header: true, body: false, display_name: nil)
      networking = allowed_hosts ? {type: "limited", allowed_hosts: Array(allowed_hosts)} : {type: "unrestricted"}
      store({type: "environment_variable", secret_name: name, secret_value: value, networking: networking,
        injection_location: {header: header, body: body}}, display_name: display_name)
    end

    def connection(key)
      connections.find_by(key: connection_key(key))
    end

    def connected?(key)
      connection(key)&.usable? || false
    end

    def disconnect(key)
      connection(key)&.destroy
    end

    private

    def connection_key(key)
      key.to_s.match?(%r{\Ahttps?://}i) ? MCP.normalize(key) : key.to_s
    end

    # Rotates in place when only the secret changed, so sessions already
    # running pick the new one up. Anything structural means a new credential.
    def store(auth, display_name: nil, details: {})
      api = ManagedAgents.client.beta.vaults.credentials
      structure = CredentialAuth.structure(auth)
      existing = connections.find_by(key: CredentialAuth.key(auth))

      if existing && existing.structure == structure
        api.update(existing.remote_id, vault_id: remote_id,
          **{display_name: display_name, auth: CredentialAuth.mutable(auth).deep_symbolize_keys}.compact)
        existing.update!(status: "active", display_name: display_name || existing.display_name, details: details.merge(structure))
        existing
      else
        existing&.destroy
        remote = api.create(remote_id, **{display_name: display_name, auth: auth}.compact)
        connections.create!(key: CredentialAuth.key(auth), kind: auth[:type], remote_id: remote.id,
          display_name: display_name, details: details.merge(structure))
      end
    end

    def archive_remote
      ManagedAgents.client.beta.vaults.archive(remote_id)
    rescue Anthropic::Errors::NotFoundError
      nil
    end
  end
end

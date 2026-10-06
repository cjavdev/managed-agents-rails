module ManagedAgents
  # The vault an agent's vault.yaml declares, as a place to put credentials
  # someone signs in for. vault.yaml names them with `connect: oauth`:
  #
  #   credentials:
  #     - display_name: Sentry
  #       connect: oauth
  #       auth:
  #         type: mcp_oauth
  #         mcp_server_url: https://mcp.sentry.dev/mcp
  #
  # `bin/rails managed_agents:connect issue_fixer` runs the sign-in and stores
  # the tokens here. Sync leaves the credential alone after that; Anthropic
  # keeps the access token fresh.
  #
  # It takes the same `connect_oauth` call as ManagedAgents::Vault, so
  # ManagedAgents::OAuth.complete can write to either.
  class AgentVault
    attr_reader :definition

    def initialize(agent_name)
      @definition = Definition.find(agent_name)
    end

    def name = definition.name

    def remote_id = Resource.remote_id!(name, "vault")

    # The credentials vault.yaml declares with `connect:`.
    def declared = definition.connected_credentials

    # The declared credential for a server URL. Raises when vault.yaml doesn't
    # declare one, so nothing lands in the vault that the files don't name.
    def credential(url)
      declared.find { |credential| MCP.normalize(server_url(credential)) == MCP.normalize(url) } ||
        raise(DefinitionError, "#{name}: vault.yaml declares no credential with connect: oauth for #{url}")
    end

    def server_url(credential) = credential.dig("auth", "mcp_server_url")

    def connected?(url)
      resource(credential(url)).present?
    end

    def connect_oauth(url, display_name: nil, **tokens)
      declared = credential(url)
      auth = CredentialAuth.mcp_oauth(server_url(declared), **tokens)
      store(declared, auth, display_name: declared["display_name"] || display_name)
    end

    # "valid", "invalid" or "unknown" (Anthropic could not reach the server).
    def validate(url)
      record = resource(credential(url)) or return "invalid"
      ManagedAgents.client.beta.vaults.credentials.mcp_oauth_validate(record.remote_id, vault_id: remote_id).status.to_s
    rescue Anthropic::Errors::NotFoundError
      "invalid"
    end

    def disconnect(url)
      record = resource(credential(url)) or return
      archive(record.remote_id)
      record.destroy!
    end

    private

    def api = ManagedAgents.client.beta.vaults.credentials

    def resource(credential) = Resource.lookup(name, "credential", Sync::Vaults.key(credential))

    # Rotates in place when only the tokens changed. A different client or
    # token endpoint needs a new credential.
    def store(declared, auth, display_name:)
      existing = resource(declared)
      digest = Sync::Digests.digest(CredentialAuth.structure(auth))
      vault_id = remote_id

      remote = if existing && existing.digest == digest
        api.update(existing.remote_id, vault_id: vault_id,
          **{display_name: display_name, auth: CredentialAuth.mutable(auth).deep_symbolize_keys}.compact)
      else
        archive(existing.remote_id) if existing
        create(vault_id, auth, display_name)
      end

      Resource.record!(agent_name: name, kind: "credential", key: Sync::Vaults.key(declared), remote_id: remote.id,
        digest: digest, backend: "api", path: definition.relative_path(definition.vault_path),
        workspace_id: ManagedAgents.config.workspace_id)
    end

    # A vault holds one active credential per server. One made outside this
    # app (an older script, the Console) is replaced.
    def create(vault_id, auth, display_name)
      api.create(vault_id, **{display_name: display_name, auth: auth}.compact)
    rescue Anthropic::Errors::ConflictError
      key = CredentialAuth.key(auth)
      api.list(vault_id).auto_paging_each do |candidate|
        archive(candidate.id) if candidate.archived_at.nil? && CredentialAuth.key(Events.to_hash(candidate.auth)) == key
      end
      api.create(vault_id, **{display_name: display_name, auth: auth}.compact)
    end

    def archive(id)
      api.archive(id, vault_id: remote_id)
    rescue Anthropic::Errors::NotFoundError
      nil
    end
  end
end

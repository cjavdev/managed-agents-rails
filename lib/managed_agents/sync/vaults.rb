module ManagedAgents
  class Sync
    # Creates the vault declared in vault.yaml and fills it with credentials
    # resolved from Rails credentials or ENV.
    class Vaults
      # What makes a credential unique inside a vault, as written in the file.
      def self.key(credential)
        auth = credential["auth"] || {}
        (auth["mcp_server_url"] || auth["secret_name"]).to_s
      end

      def self.vault_body(definition)
        {"display_name" => definition.name}.merge(definition.vault_body)
      end

      def self.vault_digest(definition)
        Digests.digest(vault_body(definition))
      end

      def self.credential_body(credential)
        {
          "display_name" => credential["display_name"],
          "metadata" => credential["metadata"],
          "auth" => Secrets.resolve(credential.fetch("auth"))
        }.compact
      end

      def self.credential_digest(credential)
        Digests.secret_digest(credential_body(credential))
      end

      def initialize(sync)
        @sync = sync
        @client = sync.client
      end

      def apply(definition)
        return [] unless definition.vault_path

        changes = [vault(definition)]
        definition.credentials.each do |credential|
          changes << (Definition.connected_credential?(credential) ? connected(definition, credential) : credential(definition, credential))
        end
        changes
      end

      private

      def vault(definition)
        body = self.class.vault_body(definition)
        digest = Digests.digest(body)
        resource = Resource.lookup(definition.name, "vault")
        action = @sync.action_for(resource, digest)

        if action != :unchanged && !@sync.dry_run
          remote = if resource
            @client.beta.vaults.update(resource.remote_id, **body.deep_symbolize_keys)
          else
            @client.beta.vaults.create(**body.deep_symbolize_keys)
          end
          resource = Resource.record!(agent_name: definition.name, kind: "vault", remote_id: remote.id,
            digest: digest, backend: "api", path: definition.relative_path(definition.vault_path),
            workspace_id: @sync.workspace_id)
        end

        @sync.say(action, definition.name, "vault", "", resource&.remote_id)
        Change.new(definition.name, "vault", "", action, resource&.remote_id)
      end

      def credential(definition, credential)
        key = self.class.key(credential)
        raise DefinitionError, "#{definition.name}: a credential needs auth.mcp_server_url or auth.secret_name" if key.blank?

        resource = Resource.lookup(definition.name, "credential", key)
        begin
          body = self.class.credential_body(credential)
        rescue MissingSecret => error
          raise unless credential["optional"]

          # Left as it is: a credential already in the vault keeps working.
          @sync.say(:skip, definition.name, "credential", key, "optional, #{error.message}")
          return Change.new(definition.name, "credential", key, :skipped, resource&.remote_id)
        end
        digest = Digests.secret_digest(body)
        action = @sync.action_for(resource, digest)

        if action != :unchanged && !@sync.dry_run
          vault_id = Resource.remote_id!(definition.name, "vault")
          remote = resource ? update(resource, vault_id, body) : create(vault_id, key, body)
          resource = Resource.record!(agent_name: definition.name, kind: "credential", key: key,
            remote_id: remote.id, digest: digest, backend: "api",
            path: definition.relative_path(definition.vault_path), workspace_id: @sync.workspace_id)
        end

        @sync.say(action, definition.name, "credential", key, resource&.remote_id)
        Change.new(definition.name, "credential", key, action, resource&.remote_id)
      end

      # Its tokens come from `managed_agents:connect`, so sync only reports it.
      def connected(definition, credential)
        key = self.class.key(credential)
        resource = Resource.lookup(definition.name, "credential", key)
        if resource
          @sync.say(:unchanged, definition.name, "credential", key, resource.remote_id)
          return Change.new(definition.name, "credential", key, :unchanged, resource.remote_id)
        end

        @sync.say(:connect, definition.name, "credential", key, "run bin/rails managed_agents:connect #{definition.name} #{key}")
        Change.new(definition.name, "credential", key, :not_connected, nil)
      end

      def create(vault_id, key, body)
        @client.beta.vaults.credentials.create(vault_id, **body.deep_symbolize_keys)
      rescue Anthropic::Errors::ConflictError
        raise SyncError, "A credential for #{key} already exists in #{vault_id}. Re-run with --adopt to take it over." unless @sync.adopt

        existing = @client.beta.vaults.credentials.list(vault_id).to_enum(:auto_paging_each).find do |candidate|
          candidate.archived_at.nil? && self.class.key("auth" => Events.to_hash(candidate.auth)) == key
        end
        raise SyncError, "Could not find the existing credential for #{key} in #{vault_id}" unless existing
        @client.beta.vaults.credentials.update(existing.id, vault_id: vault_id, **mutable(body).deep_symbolize_keys)
      end

      def update(resource, vault_id, body)
        @client.beta.vaults.credentials.update(resource.remote_id, vault_id: vault_id, **mutable(body).deep_symbolize_keys)
      end

      def mutable(body)
        body.merge("auth" => CredentialAuth.mutable(body["auth"]))
      end
    end
  end
end

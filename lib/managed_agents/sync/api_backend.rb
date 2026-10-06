module ManagedAgents
  class Sync
    # Creates and updates agents, environments and deployments with the SDK. A
    # resource is only touched when the digest of its request body changed.
    class ApiBackend
      PENDING = "(known after sync)"

      # Fields an agent update has to send explicitly, or removing them from
      # agent.md would leave the old value in place.
      AGENT_CLEARS = {system_: nil, description: nil, tools: [], mcp_servers: [], skills: []}.freeze

      def initialize(sync)
        @sync = sync
        @client = sync.client
      end

      def apply(definitions)
        # Roster agents go before their coordinator, which pins their versions.
        changes = definitions.flat_map do |definition|
          [upsert(definition, "environment"),
            *definition.roster_paths.keys.map { |key| upsert(definition, "agent", key) },
            upsert(definition, "agent")]
        end
        changes + definitions.flat_map do |definition|
          definition.deployment_paths.keys.map { |key| upsert(definition, "deployment", key) }
        end
      end

      def digest(definition, kind, key = "")
        Digests.digest(body(definition, kind, key))
      end

      private

      def upsert(definition, kind, key = "")
        body = body(definition, kind, key)
        digest = Digests.digest(body)
        resource = Resource.lookup(definition.name, kind, key)
        action = @sync.action_for(resource, digest, force: @sync.force)

        if action != :unchanged && !@sync.dry_run
          raise SyncError, "#{definition.name}: #{kind} #{key} refers to something that is not synced yet" if body.to_json.include?(PENDING)

          remote = resource ? update(kind, resource, body) : create(kind, body)
          resource = Resource.record!(agent_name: definition.name, kind: kind, key: key, remote_id: remote.id,
            remote_version: remote.try(:version)&.to_s, digest: digest, backend: "api", lock_data: nil,
            path: definition.relative_path(path(definition, kind, key)), workspace_id: @sync.workspace_id)
        end

        detail = [resource&.remote_id, resource&.remote_version && "v#{resource.remote_version}"].compact.join(" ")
        @sync.say(action, definition.name, kind, key, detail)
        Change.new(definition.name, kind, key, action, resource&.remote_id)
      end

      def create(kind, body)
        api(kind).create(**params(kind, body))
      rescue Anthropic::Errors::ConflictError
        unless @sync.adopt
          raise SyncError, "A #{kind} named #{body["name"].inspect} already exists in this workspace. " \
            "Re-run with --adopt to take it over, or rename it."
        end

        existing = api(kind).list.to_enum(:auto_paging_each).find { |candidate| candidate.name == body["name"] }
        raise SyncError, "Could not find the existing #{kind} named #{body["name"].inspect}" unless existing
        api(kind).update(existing.id, **params(kind, body))
      end

      def update(kind, resource, body)
        return api(kind).update(resource.remote_id, **params(kind, body)) unless kind == "agent"

        current = api(kind).retrieve(resource.remote_id)
        if resource.remote_version.present? && current.version.to_s != resource.remote_version && !@sync.force
          raise Drift, "Agent #{resource.agent_name} (#{resource.remote_id}) is at version #{current.version} but " \
            "version #{resource.remote_version} was recorded here: it was changed outside the definition files. " \
            "Re-run with --force to overwrite it."
        end
        api(kind).update(resource.remote_id, version: current.version, **AGENT_CLEARS.merge(params(kind, body)))
      rescue Anthropic::Errors::NotFoundError
        raise SyncError, "#{kind} #{resource.remote_id} no longer exists. Re-run with --force to create a replacement." unless @sync.force
        create(kind, body)
      end

      def api(kind)
        @client.beta.public_send(kind.pluralize)
      end

      def params(kind, body)
        params = body.deep_symbolize_keys
        # `system` would shadow Kernel#system, so the SDK calls it `system_`.
        params[:system_] = params.delete(:system) if kind == "agent" && params.key?(:system)
        params
      end

      def path(definition, kind, key)
        case kind
        when "environment" then definition.environment_path
        when "agent" then definition.agent_document_path(key)
        when "deployment" then definition.deployment_paths.fetch(key)
        end
      end

      def body(definition, kind, key)
        case kind
        when "environment" then definition.environment_body
        when "agent" then agent_body(definition, key)
        when "deployment" then deployment_body(definition, key)
        end
      end

      def agent_body(definition, key)
        body = definition.agent_body(key)
        roster = body.dig("multiagent", "agents")
        return body unless roster.is_a?(Array)

        from = definition.agent_document_path(key)
        body.deep_dup.tap do |resolved|
          resolved["multiagent"]["agents"] = roster.map { |value| agent_reference(definition, value, from) }
        end
      end

      def deployment_body(definition, key)
        document = definition.deployments.fetch(key)
        from = document.path
        body = document.data.except("type").deep_dup

        body["agent"] = agent_reference(definition, body["agent"], from)
        body["environment_id"] = remote_id(definition, body["environment_id"], from)
        body["vault_ids"] = body["vault_ids"].map { |value| remote_id(definition, value, from) } if body["vault_ids"]
        if document.body && body["initial_events"].blank?
          body["initial_events"] = [Events.user_message(document.body).deep_stringify_keys]
        end
        body
      end

      def remote_id(definition, value, from)
        reference = definition.resolve_reference(value, from: from) or return value
        Resource.lookup(reference.agent_name, reference.kind, reference.key)&.remote_id || PENDING
      end

      # Pins the deployment to the agent version that was just synced, so an
      # agent update re-pins every deployment that points at it.
      def agent_reference(definition, value, from)
        reference = definition.resolve_reference(value, from: from) or return value
        resource = Resource.lookup(reference.agent_name, reference.kind, reference.key) or return PENDING
        return resource.remote_id if resource.remote_version.blank?

        {"type" => "agent", "id" => resource.remote_id, "version" => resource.remote_version.to_i}
      end
    end
  end
end

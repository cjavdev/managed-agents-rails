module ManagedAgents
  class Sync
    # Creates and updates the memory stores declared as memory.yaml or
    # memory-<key>.yaml in an agent's folder, always through the SDK (`ant
    # apply` does not manage them). A store is only touched when its name,
    # description or metadata changed; what the agents wrote into it is theirs.
    class MemoryStores
      def self.digest(definition, key)
        Digests.digest(definition.memory_store_body(key))
      end

      def initialize(sync)
        @sync = sync
        @client = sync.client
      end

      def apply(definition)
        definition.memory_paths.keys.map { |key| upsert(definition, key) }
      end

      private

      def upsert(definition, key)
        body = definition.memory_store_body(key)
        digest = Digests.digest(body)
        resource = Resource.lookup(definition.name, "memory_store", key)
        action = @sync.action_for(resource, digest)

        if action != :unchanged && !@sync.dry_run
          params = body.deep_symbolize_keys
          remote = resource ? @client.beta.memory_stores.update(resource.remote_id, **params) : @client.beta.memory_stores.create(**params)
          resource = Resource.record!(agent_name: definition.name, kind: "memory_store", key: key, remote_id: remote.id,
            digest: digest, backend: "api", path: definition.relative_path(definition.memory_paths.fetch(key)),
            workspace_id: @sync.workspace_id)
        end

        @sync.say(action, definition.name, "memory_store", key, resource&.remote_id)
        Change.new(definition.name, "memory_store", key, action, resource&.remote_id)
      end
    end
  end
end

require "digest"
require "zlib"
require "managed_agents/sync/change"
require "managed_agents/sync/vaults"
require "managed_agents/sync/api_backend"
require "managed_agents/sync/ant_backend"

module ManagedAgents
  # Makes the Claude API match the files under app/agents, and records every
  # remote ID in the database. The Rails equivalent of this is db:migrate: run
  # it on deploy, in every environment, against that environment's workspace.
  #
  # Two backends do the work. `ant apply` is used when the CLI is installed;
  # otherwise the SDK creates and updates the resources directly. Vaults and
  # their credentials always go through the SDK, because `ant apply` does not
  # manage credentials.
  class Sync
    attr_reader :dry_run, :force, :prune, :adopt, :io, :client

    def initialize(only: nil, backend: nil, dry_run: false, force: false, prune: false, adopt: false,
      io: $stdout, client: nil)
      @only = only
      @requested_backend = backend
      @dry_run = dry_run
      @force = force
      @prune = prune
      @adopt = adopt
      @io = io
      @client = client || ManagedAgents.client
    end

    def apply
      check!
      verify_workspace!

      exclusively do
        changes = definitions.flat_map { |definition| Vaults.new(self).apply(definition) }
        changes += backend.apply(definitions)
        changes += orphans.map { |resource| remove(resource) }

        report(changes)
        changes
      end
    end

    def definitions
      @definitions ||= @only ? [Definition.find(@only)] : Definition.all
    end

    def problems
      found = definitions.flat_map(&:problems)
      definitions.each do |definition|
        handlers = Agent.for(definition.name).tools.keys
        declared = definition.custom_tools.map { |tool| tool["name"] }
        (declared - handlers).each { |tool| found << "#{definition.name}: custom tool #{tool} has no handler" }
        (handlers - declared).each { |tool| found << "#{definition.name}: handler #{tool} is not declared in agent.md" }
      rescue DefinitionError
        next
      end
      found
    end

    # One row per resource, for `managed_agents:status`.
    def status
      rows = definitions.flat_map do |definition|
        expected(definition).map do |kind, key, path|
          resource = Resource.lookup(definition.name, kind, key)
          state = "not synced" unless resource
          state ||= (resource.digest == current_digest(definition, kind, key, resource)) ? "synced" : "pending"
          [definition.name, label(kind, key), resource&.remote_id, resource&.remote_version, state]
        end
      end
      rows + orphans.map { |resource| [resource.agent_name, label(resource.kind, resource.key), resource.remote_id, resource.remote_version, "orphaned"] }
    end

    def backend_name
      @backend_name ||= begin
        requested = (@requested_backend || ManagedAgents.config.sync_backend).to_s
        existing = Resource.where(kind: %w[agent environment deployment]).distinct.pluck(:backend).compact

        case requested
        when "api" then "api"
        when "ant"
          raise SyncError, "The ant CLI (1.34 or newer) was not found on PATH" unless AntBackend.available?
          if existing.include?("api")
            raise SyncError, "These resources were created through the API. `ant apply` cannot adopt them " \
              "and would create duplicates, so keep using the api backend for this database."
          end
          "ant"
        else
          (!existing.include?("api") && AntBackend.available?) ? "ant" : "api"
        end
      end
    end

    def workspace_id
      ManagedAgents.config.workspace_id
    end

    def action_for(resource, digest, force: false)
      return :create unless resource

      (resource.digest != digest || force) ? :update : :unchanged
    end

    def say(action, definition_name, kind, key = "", detail = nil)
      io.puts format("  %-10s %-16s %-24s %s", action, definition_name, label(kind, key), detail).rstrip
    end

    private

    def backend
      @backend ||= ((backend_name == "ant") ? AntBackend : ApiBackend).new(self)
    end

    def backend_for(resource)
      @backends ||= {"ant" => AntBackend.new(self), "api" => ApiBackend.new(self)}
      @backends.fetch(resource.backend || "api")
    end

    def current_digest(definition, kind, key, resource)
      case kind
      when "vault" then Vaults.vault_digest(definition)
      when "credential"
        Vaults.credential_digest(definition.credentials.find { |credential| Vaults.key(credential) == key })
      else backend_for(resource).digest(definition, kind, key)
      end
    rescue MissingSecret
      nil
    end

    # Two deploys syncing at once would each create the same resources. Where
    # the database has advisory locks (PostgreSQL, MySQL) the second one stops.
    def exclusively
      return yield if dry_run

      Resource.with_connection do |connection|
        next yield unless connection.supports_advisory_locks?

        lock = Zlib.crc32("managed_agents:sync")
        raise SyncError, "Another managed_agents:sync is already running against this database" unless connection.get_advisory_lock(lock)

        begin
          yield
        ensure
          connection.release_advisory_lock(lock)
        end
      end
    end

    def check!
      found = definitions.flat_map(&:problems)
      raise DefinitionError, found.join("\n") if found.any?
    end

    def verify_workspace!
      recorded = Resource.workspace_ids
      return if workspace_id.nil? || recorded.empty? || recorded == [workspace_id]

      raise WorkspaceMismatch, "This database holds IDs from workspace #{recorded.join(", ")}, but the " \
        "current credentials are for #{workspace_id}. Point at the right workspace or use a separate database."
    end

    def expected(definition)
      rows = [["environment", "", definition.environment_path], ["agent", "", definition.agent_path]]
      rows << ["vault", "", definition.vault_path] if definition.vault_path
      definition.credentials.each { |credential| rows << ["credential", Vaults.key(credential), definition.vault_path] }
      definition.deployment_paths.each { |key, path| rows << ["deployment", key, path] }
      rows
    end

    # Rows whose file (or whole agent folder) is gone.
    def orphans
      return [] if @only

      known = definitions.flat_map { |definition| expected(definition).map { |kind, key, _| [definition.name, kind, key] } }
      Resource.all.reject { |resource| known.include?([resource.agent_name, resource.kind, resource.key]) }
        .sort_by { |resource| -Resource::KINDS.index(resource.kind) }
    end

    def remove(resource)
      unless prune
        say("orphaned", resource.agent_name, resource.kind, resource.key, "#{resource.remote_id} (pass --prune to archive)")
        return Change.new(resource.agent_name, resource.kind, resource.key, :orphaned, resource.remote_id)
      end

      unless dry_run
        archive(resource)
        resource.destroy!
      end
      say("archive", resource.agent_name, resource.kind, resource.key, resource.remote_id)
      Change.new(resource.agent_name, resource.kind, resource.key, :archive, resource.remote_id)
    end

    def archive(resource)
      case resource.kind
      when "agent" then client.beta.agents.archive(resource.remote_id)
      when "environment" then client.beta.environments.archive(resource.remote_id)
      when "deployment" then client.beta.deployments.archive(resource.remote_id)
      when "vault" then client.beta.vaults.archive(resource.remote_id)
      when "credential"
        vault = Resource.lookup(resource.agent_name, "vault")
        client.beta.vaults.credentials.archive(resource.remote_id, vault_id: vault.remote_id) if vault
      end
    rescue Anthropic::Errors::NotFoundError
      nil
    end

    def report(changes)
      counts = changes.group_by(&:action).transform_values(&:size)
      summary = %i[create update unchanged archive orphaned].filter_map { |action| "#{counts[action]} #{action}" if counts[action] }
      io.puts "#{dry_run ? "Plan" : "Synced"} (#{backend_name} backend): #{summary.join(", ").presence || "nothing to do"}"
    end

    def label(kind, key)
      key.present? ? "#{kind} #{key}" : kind.to_s
    end
  end
end

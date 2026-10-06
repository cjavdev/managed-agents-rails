require "open3"
require "fileutils"

module ManagedAgents
  class Sync
    # Hands the definitions to `ant apply`.
    #
    # `ant` keeps its state in a lockfile; here that state lives in the
    # database. Each run writes the rendered definitions and a lockfile rebuilt
    # from the database into tmp/managed_agents/build, runs `ant apply` there,
    # and reads the lockfile back. The lockfile is never committed.
    class AntBackend
      MINIMUM_VERSION = Gem::Version.new("1.34.0")
      LOCKFILE = "claude-lock.json"

      def self.available?(bin = ManagedAgents.config.ant_bin)
        output, status = Open3.capture2e(bin, "--version")
        status.success? && Gem::Version.new(output[/\d+\.\d+\.\d+/]) >= MINIMUM_VERSION
      rescue Errno::ENOENT, ArgumentError
        false
      end

      def initialize(sync)
        @sync = sync
      end

      def apply(definitions)
        files = build(definitions)
        before = lock_entries
        output, status = Open3.capture2e(environment, *command(files), chdir: build_root.to_s)
        @sync.io.puts output.gsub(/^/, "  ")

        after = @sync.dry_run ? before : record(read_lock)
        raise SyncError, "`ant apply` failed (exit #{status.exitstatus}). See the output above." unless status.success?

        after.map do |path, entry|
          action = :create unless before.key?(path)
          action ||= (before[path] == entry) ? :unchanged : :update
          name, kind, key = identify(path)
          Change.new(name, kind, key, action, entry["id"])
        end
      end

      def command(files)
        command = [ManagedAgents.config.ant_bin, "apply"]
        command << (@sync.dry_run ? "--dry-run" : "--yes")
        command << "--verbose" if @sync.dry_run
        command << "--force" if @sync.force
        command.push("--lock-file", LOCKFILE, *files)
      end

      def digest(definition, kind, key = "")
        Digest::SHA256.hexdigest(source(definition, kind, key))[0, 32]
      end

      def build_root
        Rails.root.join("tmp/managed_agents/build")
      end

      private

      # Returns the files to apply, relative to the build directory.
      def build(definitions)
        FileUtils.rm_rf(build_root)
        FileUtils.mkdir_p(build_root)

        files = definitions.flat_map do |definition|
          sources(definition).map do |path, source|
            relative = definition.relative_path(path)
            target = build_root.join(relative)
            FileUtils.mkdir_p(target.dirname)
            File.write(target, source)
            relative
          end
        end
        write_lock
        files
      end

      def sources(definition)
        # Skill files are copied as they are; `ant apply` uploads the skills an
        # agent references.
        sources = definition.skill_paths.keys.flat_map { |key| definition.skill_files(key).values }
          .to_h { |path| [path, path.binread] }
        sources[definition.environment_path] = source(definition, "environment")
        definition.roster_paths.each { |key, path| sources[path] = source(definition, "agent", key) }
        sources[definition.agent_path] = source(definition, "agent")
        definition.deployment_paths.each { |key, path| sources[path] = source(definition, "deployment", key) }
        sources
      end

      def source(definition, kind, key = "")
        case kind
        when "skill" then definition.skill_files(key).map { |name, path| "#{name}:#{Digest::SHA256.file(path).hexdigest}" }.join("\n")
        when "environment" then definition.environment.to_source
        when "agent" then definition.agent_document(key).to_source
        when "deployment" then deployment_source(definition, definition.deployments.fetch(key))
        end
      end

      # `ant apply` resolves the agent and environment paths itself, but sends
      # `vault_ids` as written, so vault paths are swapped for IDs here.
      def deployment_source(definition, document)
        vault_ids = document.data["vault_ids"]
        return document.to_source if vault_ids.blank?

        resolved = vault_ids.map do |value|
          reference = definition.resolve_reference(value, from: document.path) or next value
          Resource.lookup(reference.agent_name, reference.kind, reference.key)&.remote_id || ApiBackend::PENDING
        end
        document.to_source(document.data.merge("vault_ids" => resolved))
      end

      def lock_path
        build_root.join(LOCKFILE)
      end

      def tracked
        Resource.where(backend: "ant").where.not(path: nil)
      end

      def lock_entries
        tracked.to_h { |resource| ["./#{resource.path}", resource.lock_data&.dig("entry")] }
      end

      def write_lock
        resources = tracked.to_a
        return if resources.empty?

        data = resources.first.lock_data || {}
        lock = {
          version: data["version"] || 1,
          origin: data["origin"],
          resources: resources.to_h { |resource| ["./#{resource.path}", resource.lock_data["entry"]] }
        }
        File.write(lock_path, JSON.pretty_generate(lock))
      end

      def read_lock
        lock_path.exist? ? JSON.parse(lock_path.read) : {"resources" => {}}
      end

      # `ant apply` writes what it created even when it fails partway, so the
      # lockfile is recorded before the exit status is looked at.
      def record(lock)
        lock.fetch("resources", {}).each do |path, entry|
          name, kind, key = identify(path)
          next unless name

          Resource.record!(agent_name: name, kind: kind, key: key, remote_id: entry["id"],
            remote_version: entry["version"]&.to_s, backend: "ant", path: path.delete_prefix("./"),
            digest: (kind == "skill") ? digest(Definition.find(name), kind, key) : staged_digest(path), workspace_id: lock.dig("origin", "workspace_id"),
            lock_data: {"version" => lock["version"], "origin" => lock["origin"], "entry" => entry})
        end
        lock.fetch("resources", {})
      end

      def staged_digest(path)
        staged = build_root.join(path)
        Digest::SHA256.hexdigest(staged.read)[0, 32] if staged.file?
      end

      # "./app/agents/support_triage/deployment-daily.yaml" -> ["support_triage", "deployment", "daily"]
      # "./app/agents/desk/skills/voice" -> ["desk", "skill", "voice"]
      def identify(path)
        file = Pathname(path.delete_prefix("./"))
        file = file.dirname if file.basename.to_s == "SKILL.md"
        return [file.dirname.dirname.basename.to_s, "skill", file.basename.to_s] if file.dirname.basename.to_s == "skills"

        name = file.dirname.basename.to_s
        base = file.basename.to_s

        if (match = base.match(Definition::DEPLOYMENT))
          [name, "deployment", match[:key] || "default"]
        elsif (match = base.match(Definition::ROSTER))
          [name, "agent", match[:key]]
        elsif (kind = %w[agent environment].find { |candidate| base.start_with?(candidate) })
          [name, kind, ""]
        end
      end

      # The CLI resolves credentials the way the SDK does. An API key that only
      # exists in Rails credentials has to be passed along.
      def environment
        key = ManagedAgents.config.api_key || Secrets.lookup("anthropic.api_key")
        (key && ENV["ANTHROPIC_API_KEY"].blank?) ? {"ANTHROPIC_API_KEY" => key} : {}
      end
    end
  end
end

module ManagedAgents
  # The files for one agent: app/agents/<name>/{agent.md, environment.yaml,
  # vault.yaml, deployment-*.yaml}, plus agent-<role>.md for each roster agent
  # of a multiagent coordinator and skills/<skill>/SKILL.md for each custom
  # skill its agents use.
  class Definition
    EXTENSIONS = %w[md yaml yml].freeze
    DEPLOYMENT = /\Adeployment(?:[-_](?<key>.+))?\.(?:md|ya?ml)\z/
    ROSTER = /\Aagent[-_](?<key>.+)\.(?:md|ya?ml)\z/

    Reference = Struct.new(:agent_name, :kind, :key)

    attr_reader :name, :root

    class << self
      def all
        Dir.children(root).sort.filter_map do |entry|
          definition = new(entry)
          definition if definition.exist?
        end
      rescue Errno::ENOENT
        []
      end

      def find(name)
        candidates = [name.to_s, name.to_s.tr("_", "-"), name.to_s.tr("-", "_")].uniq
        candidates.map { |candidate| new(candidate) }.find(&:exist?) ||
          raise(DefinitionError, "No agent definition at #{root.join(name.to_s, "agent.md")}")
      end

      def root
        ManagedAgents.config.agents_root
      end
    end

    def initialize(name)
      @name = name.to_s
      @root = self.class.root.join(@name)
    end

    def exist?
      !agent_path.nil?
    end

    def agent_path = file("agent")

    def environment_path = file("environment")

    def vault_path = file("vault")

    def deployment_paths
      return {} unless root.directory?

      root.children.sort.each_with_object({}) do |path, found|
        match = path.basename.to_s.match(DEPLOYMENT)
        found[match[:key] || "default"] = path if match
      end
    end

    # Roster agents a coordinator delegates to, keyed by role:
    # agent-writer.md is "writer". They run as threads of the coordinator's
    # sessions and are referenced from its `multiagent.agents` by path.
    def roster_paths
      return {} unless root.directory?

      root.children.sort.each_with_object({}) do |path, found|
        match = path.basename.to_s.match(ROSTER)
        found[match[:key]] = path if match
      end
    end

    def roster
      roster_paths.transform_values { |path| document(path) }
    end

    # Custom skills, keyed by directory name: skills/<skill>/SKILL.md plus any
    # files beside it.
    def skill_paths
      skills = root.join("skills")
      return {} unless skills.directory?

      skills.children.sort.select { |path| path.join("SKILL.md").file? }.to_h { |path| [path.basename.to_s, path] }
    end

    # Every file of a skill, keyed by the name it is uploaded under. The API
    # wants them all inside one top-level directory named for the skill.
    def skill_files(key)
      dir = skill_paths.fetch(key.to_s)
      dir.glob("**/*").select(&:file?).sort.to_h { |file| ["#{key}/#{file.relative_path_from(dir)}", file] }
    end

    def agent = document(agent_path)

    # The coordinator for "", a roster agent for its role.
    def agent_document(key = "")
      key.to_s.empty? ? agent : document(roster_paths.fetch(key.to_s))
    end

    def agent_document_path(key = "")
      key.to_s.empty? ? agent_path : roster_paths.fetch(key.to_s)
    end

    def environment = document(environment_path)

    def vault = document(vault_path)

    def deployments
      deployment_paths.transform_values { |path| document(path) }
    end

    # The agents.create body: frontmatter plus the Markdown body as `system`.
    def agent_body(key = "")
      document = agent_document(key)
      body = document.data.except("type", "environment")
      body["system"] ||= document.body if document.body
      body
    end

    def environment_body
      environment.data.except("type")
    end

    # Another agent's environment.yaml, when agent.md names one with
    # `environment: ../other/environment.yaml`, so several agents boot from
    # one environment. Nil when the agent has its own.
    def environment_reference
      value = agent.data["environment"]
      return if value.nil?

      reference = resolve_reference(value, from: agent_path) if value.is_a?(String)
      unless reference&.kind == "environment" && reference.key.empty?
        raise DefinitionError, "#{name}: environment must be a relative path to another agent's environment.yaml, " \
          "got #{value.inspect}"
      end
      reference
    end

    def shared_environment? = !environment_reference.nil?

    # The agent folder whose environment sessions of this agent run in.
    def environment_owner
      environment_reference&.agent_name || name
    end

    def vault_body
      vault.data.slice("display_name", "metadata")
    end

    def credentials
      Array(vault&.data&.fetch("credentials", nil))
    end

    # A credential whose tokens come from signing in (`connect: oauth`), not
    # from the file: `bin/rails managed_agents:connect` puts them in the vault.
    def self.connected_credential?(credential) = credential.key?("connect")

    def connected_credentials
      credentials.select { |credential| self.class.connected_credential?(credential) }
    end

    # Custom tools of the coordinator and its roster: a roster agent's calls
    # arrive in the coordinator's session and are answered by the same class.
    def custom_tools
      [agent, *roster.values].flat_map { |document| Array(document.data["tools"]) }
        .select { |tool| tool["type"] == "custom" }.uniq { |tool| tool["name"] }
    end

    def custom_tool(name)
      custom_tools.find { |tool| tool["name"] == name.to_s }
    end

    def relative_path(path)
      Pathname(path).relative_path_from(Rails.root).to_s
    end

    # What a relative path written in one of this agent's files points at.
    def resolve_reference(value, from:)
      return unless value.is_a?(String)

      target = Pathname(from).dirname.join(value).cleanpath
      return resolve_skill(target) if target.dirname.basename.to_s == "skills"
      return unless value.match?(/\.(md|ya?ml)\z/)

      owner = self.class.new(target.dirname.basename.to_s)
      return unless target.dirname == owner.root

      base = target.basename.to_s
      if (match = base.match(DEPLOYMENT))
        Reference.new(owner.name, "deployment", match[:key] || "default")
      elsif (match = base.match(ROSTER))
        Reference.new(owner.name, "agent", match[:key])
      elsif (kind = %w[agent environment vault].find { |candidate| base.start_with?(candidate) })
        Reference.new(owner.name, kind, "")
      end
    end

    def problems
      problems = []
      check(problems) { check_environment(problems) }
      check(problems) { problems << "#{name}: agent needs a name" if agent.data["name"].blank? }
      check(problems) { problems << "#{name}: agent needs a model" if agent.data["model"].blank? }
      check(problems) do
        roster.each do |key, document|
          %w[name model].each { |field| problems << "#{name}: roster agent #{key} needs a #{field}" if document.data[field].blank? }
        end
      end
      check(problems) { environment if environment_path }
      check(problems) do
        deployments.each do |key, deployment|
          %w[agent environment_id].each do |field|
            problems << "#{name}: deployment #{key} needs #{field}" if deployment.data[field].blank?
          end
          if deployment.body.nil? && deployment.data["initial_events"].blank?
            problems << "#{name}: deployment #{key} needs initial_events or a Markdown body"
          end
        end
      end
      check(problems) do
        credentials.each do |credential|
          next check_connected(problems, credential) if self.class.connected_credential?(credential)

          Secrets.resolve(credential.fetch("auth", {}))
        rescue MissingSecret
          raise unless credential["optional"]
        end
      end
      problems
    end

    private

    def check_environment(problems)
      reference = environment_reference
      if reference.nil?
        problems << "#{name}: environment.yaml is missing" unless environment_path
      elsif environment_path
        problems << "#{name}: has its own environment.yaml and also uses #{agent.data["environment"]}; keep one"
      elsif reference.agent_name == name || !self.class.new(reference.agent_name).environment_path
        problems << "#{name}: environment #{agent.data["environment"]} does not point at another agent's environment.yaml"
      end
    end

    def resolve_skill(target)
      owner = self.class.new(target.dirname.dirname.basename.to_s)
      Reference.new(owner.name, "skill", target.basename.to_s) if owner.skill_paths[target.basename.to_s] == target
    end

    def check_connected(problems, credential)
      auth = credential["auth"].to_h
      label = auth["mcp_server_url"] || credential["display_name"] || "a credential"
      problems << "#{name}: #{label}: connect must be oauth" unless credential["connect"] == "oauth"
      unless auth["type"] == "mcp_oauth" && auth["mcp_server_url"].present?
        problems << "#{name}: #{label}: a connected credential needs auth.type mcp_oauth and auth.mcp_server_url"
      end
      extra = auth.keys - %w[type mcp_server_url]
      problems << "#{name}: #{label}: #{extra.join(", ")} come from signing in, not from vault.yaml" if extra.any?
    end

    def check(problems)
      yield
    rescue DefinitionError, MissingSecret => error
      problems << "#{name}: #{error.message}"
    end

    def file(kind)
      EXTENSIONS.map { |extension| root.join("#{kind}.#{extension}") }.find(&:file?)
    end

    def document(path)
      return unless path
      @documents ||= {}
      @documents[path] ||= Document.load(path)
    end
  end
end

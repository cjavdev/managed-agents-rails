module ManagedAgents
  # The files for one agent: app/agents/<name>/{agent.md, environment.yaml,
  # vault.yaml, deployment-*.yaml}, plus agent-<role>.md for each roster agent
  # of a multiagent coordinator.
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
      body = document.data.except("type")
      body["system"] ||= document.body if document.body
      body
    end

    def environment_body
      environment.data.except("type")
    end

    def vault_body
      vault.data.slice("display_name", "metadata")
    end

    def credentials
      Array(vault&.data&.fetch("credentials", nil))
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
      return unless value.is_a?(String) && value.match?(/\.(md|ya?ml)\z/)

      target = Pathname(from).dirname.join(value).cleanpath
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
      problems << "#{name}: environment.yaml is missing" unless environment_path
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
          Secrets.resolve(credential.fetch("auth", {}))
        end
      end
      problems
    end

    private

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

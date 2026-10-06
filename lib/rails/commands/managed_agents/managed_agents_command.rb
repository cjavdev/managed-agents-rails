require "rails/command/environment_argument"

module Rails
  module Command
    class ManagedAgentsCommand < Base # :nodoc:
      include EnvironmentArgument

      desc "create", "Scaffold a new agent under app/agents"
      option :name, type: :string, required: true, desc: "Folder name of the agent, e.g. support_triage"
      option :deployments, type: :array, default: [], desc: "Scheduled deployments to scaffold, e.g. daily hourly-title"
      option :vault, type: :boolean, default: false, desc: "Scaffold a vault.yaml for credentials"
      option :model, type: :string, desc: "Claude model ID"
      def create
        arguments = ["managed_agents:agent", options[:name]]
        arguments.push("--deployments", *options[:deployments]) if options[:deployments].any?
        arguments << "--vault" if options[:vault]
        arguments.push("--model", options[:model]) if options[:model]
        Rails::Command.invoke :generate, arguments
      end

      desc "sync", "Create or update the agents, environments, vaults and deployments defined under app/agents"
      option :dry_run, type: :boolean, default: false, desc: "Show what would change without changing anything"
      option :only, type: :string, desc: "Sync a single agent folder"
      option :backend, type: :string, enum: %w[auto ant api], desc: "How to apply: the ant CLI or the API"
      option :force, type: :boolean, default: false, desc: "Overwrite resources that were changed outside the files"
      option :prune, type: :boolean, default: false, desc: "Archive remote resources whose files were deleted"
      option :adopt, type: :boolean, default: false, desc: "Take over an existing resource with the same name"
      def sync
        boot_application!
        guard do
          ManagedAgents::Sync.new(only: options[:only], backend: options[:backend], dry_run: options[:dry_run],
            force: options[:force], prune: options[:prune], adopt: options[:adopt]).apply
        end
      end

      desc "status", "Show which definitions are synced, pending or orphaned"
      option :validate, type: :boolean, default: false, desc: "Also check that signed-in credentials still work"
      def status
        boot_application!
        guard do
          rows = ManagedAgents::Sync.new.status(validate: options[:validate])
          print_table([%w[Agent Resource ID Version State], *rows.map { |row| row.map(&:to_s) }])
          exit 1 if rows.any? { |row| !ManagedAgents::Sync::STATES_OK.include?(row.last) }
        end
      end

      desc "connect AGENT [URL]", "Sign in to an MCP server that the agent's vault.yaml declares with connect: oauth"
      option :redirect_uri, type: :string, default: "http://localhost:8976/callback",
        desc: "Where the authorization server sends the browser back to"
      option :listen, type: :boolean, default: true, desc: "Wait for the browser on the redirect URI's port as well as for a pasted address"
      def connect(agent_name = nil, url = nil)
        boot_application!
        guard do
          raise ManagedAgents::Error, "Name the agent: bin/rails managed_agents:connect AGENT [URL]" if agent_name.blank?

          vault = ManagedAgents::AgentVault.new(agent_name)
          declared = vault.declared
          raise ManagedAgents::Error, "#{vault.name}: vault.yaml declares no credential with connect: oauth" if declared.empty?
          if url.blank?
            raise ManagedAgents::Error, "#{vault.name} declares several; name one: #{declared.map { |c| vault.server_url(c) }.join(", ")}" if declared.many?
            url = vault.server_url(declared.sole)
          end

          credential = vault.credential(url)
          ManagedAgents::OAuth::Terminal.new(vault, vault.server_url(credential), redirect_uri: options[:redirect_uri],
            scope: credential["scope"], listen: options[:listen]).run
          say "Connected #{vault.server_url(credential)} in #{vault.name}'s vault."
        end
      end

      desc "check", "Validate the definition files and tool handlers without calling the API"
      def check
        boot_application!
        guard do
          problems = ManagedAgents::Sync.new.problems
          if problems.empty?
            say "#{ManagedAgents.definitions.size} agent definition(s) look good"
          else
            problems.each { |problem| say_error problem }
            exit 1
          end
        end
      end

      private

      def guard
        yield
      rescue ManagedAgents::Error, Anthropic::Errors::Error => error
        say_error "#{error.class.name.demodulize}: #{error.message}"
        exit 1
      end
    end
  end
end

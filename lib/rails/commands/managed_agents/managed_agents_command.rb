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
      def status
        boot_application!
        guard do
          rows = ManagedAgents::Sync.new.status
          print_table([%w[Agent Resource ID Version State], *rows.map { |row| row.map(&:to_s) }])
          exit 1 if rows.any? { |row| row.last != "synced" }
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

module ManagedAgents
  # Sync as a deploy step (Render's pre-deploy command, a Heroku release
  # phase, a Kamal hook), after db:migrate:
  #
  #   bin/rails db:migrate && bin/rails managed_agents:deploy
  #
  # It rebuilds anything deleted outside the files and takes over a leftover
  # of the same name. It does not fail the deploy: if the sync cannot run (the
  # API is down, credentials are missing), the agents keep their last synced
  # versions and the error is reported. What needs a person comes back in a
  # Report and as an ActiveSupport notification an app can alert on:
  #
  #   ActiveSupport::Notifications.subscribe("deploy.managed_agents") do |event|
  #     report = event.payload[:report]
  #     Alerts.page(report.summary) if report.attention?
  #   end
  module Deploy
    # missing_secrets: credentials skipped because their secret is not set
    #                  (each Change's detail says which, and where to set it)
    # sign_ins:        credentials that come from signing in (connect: oauth)
    # error:           the exception that stopped the sync, if one did
    Report = Data.define(:changes, :missing_secrets, :sign_ins, :error) do
      def ok? = error.nil?

      def attention? = !ok? || missing_secrets.any? || sign_ins.any?

      def sign_in_commands
        sign_ins.map { |change| "bin/rails managed_agents:connect #{change.agent_name} #{change.key}" }
      end

      # One line per thing that needs a person.
      def summary
        lines = []
        lines << "Sync failed (#{error.class.name.demodulize}): #{error.message}. The agents keep their last synced versions." if error
        missing_secrets.each { |change| lines << "#{change.agent_name}: #{change.detail || "no secret for #{change.key}"}" }
        sign_in_commands.each { |command| lines << "Sign in: #{command}" }
        lines.join("\n")
      end
    end

    EVENT = "deploy.managed_agents".freeze

    module_function

    # Options go to Sync (only:, verify:, prune:, ...). raise_errors: true
    # lets an error stop the deploy instead.
    def run(io: $stdout, adopt: true, raise_errors: false, **)
      report = begin
        changes = Sync.new(adopt: adopt, io: io, **).apply
        Report.new(changes: changes,
          missing_secrets: changes.select { |change| change.kind == "credential" && change.action == :skipped },
          sign_ins: changes.select { |change| change.action == :not_connected },
          error: nil)
      rescue => error
        raise if raise_errors

        Rails.error.report(error, handled: true, context: {task: "managed_agents:deploy"})
        Report.new(changes: [], missing_secrets: [], sign_ins: [], error: error)
      end

      io.puts "Needs attention:\n#{report.summary.gsub(/^/, "  ")}" if report.attention?
      ActiveSupport::Notifications.instrument(EVENT, report: report)
      report
    end
  end
end

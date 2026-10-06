module ManagedAgents
  # Base class for the Ruby side of an agent. The definition (model, prompt,
  # tool schemas) lives in app/agents/<name>/; a subclass adds what has to run
  # inside the app: custom tool handlers and callbacks.
  #
  #   class SupportTriageAgent < ApplicationAgent
  #     tool :set_priority do |input|
  #       subject.update!(priority: input[:priority])
  #       {ok: true}
  #     end
  #
  #     after_turn { subject.update!(summary: session.last_agent_message) }
  #   end
  #
  #   SupportTriageAgent.start("Triage this ticket", subject: ticket)
  class Agent
    class_attribute :tools, default: {}
    class_attribute :turn_callbacks, default: []
    class_attribute :error_callbacks, default: []
    class_attribute :default_vaults, default: [:agent]

    class << self
      attr_writer :agent_name

      def for(name)
        key = name.to_s.tr("-", "_")
        named = "#{key.camelize}Agent".safe_constantize
        return named if named.is_a?(Class) && named < Agent

        base = "ApplicationAgent".safe_constantize
        base = Agent unless base.is_a?(Class) && base <= Agent
        Class.new(base).tap { |anonymous| anonymous.agent_name = name.to_s }
      end

      # SupportTriageAgent is "support_triage". An unnamed subclass is the same
      # agent as its parent.
      def agent_name
        @agent_name ||= name&.delete_suffix("Agent")&.underscore.presence ||
          ((superclass < Agent) ? superclass.agent_name : raise(Error, "Set `self.agent_name = \"...\"` on anonymous agent classes"))
      end

      def definition
        Definition.find(agent_name)
      end

      # Handles a custom tool declared in agent.md. The block runs on an agent
      # instance, so `session` and `subject` are available.
      def tool(name, &handler)
        self.tools = tools.merge(name.to_s => handler)
      end

      # The vaults a session gets unless `start` is told otherwise, in order of
      # precedence. See ManagedAgents::VaultChain for what an entry can be.
      #
      #   vaults :owner, :account, :agent   # personal, then the account's, then vault.yaml
      #
      # Personal vaults only make sense for sessions a person started. Work
      # the app starts on its own should name service-account vaults only.
      def vaults(*sources)
        self.default_vaults = sources.flatten
      end

      # Runs when the agent finishes a turn.
      def after_turn(method_name = nil, &block)
        self.turn_callbacks += [method_name || block]
      end

      # Runs on session.error events and when the session terminates.
      def on_error(method_name = nil, &block)
        self.error_callbacks += [method_name || block]
      end

      def agent_id = Resource.remote_id!(definition.name, "agent")

      def environment_id = Resource.remote_id!(definition.environment_owner, "environment")

      def agent_version
        Resource.lookup(definition.name, "agent")&.remote_version&.to_i
      end

      def vault_chain(vaults = default_vaults, owner: nil)
        VaultChain.new(vaults, agent: self, owner: owner)
      end

      # MCP servers this agent declares that no vault in the chain has a
      # credential for. A session started without them would fail to connect.
      def missing_connections(owner: nil, vaults: default_vaults)
        chain = vault_chain(vaults, owner: owner)
        MCP.servers([definition]).reject { |server| chain.covers?(server.url) }
      end

      def synced?
        Resource.lookup(definition.name, "agent").present? && Resource.lookup(definition.environment_owner, "environment").present?
      end

      # Creates a session and, when given a message, sends it and starts
      # following the session in a background job.
      #
      #   owner:    who the session belongs to, for scoping who may see it
      #   vaults:   whose credentials it acts with, in order of precedence;
      #             defaults to the agent's `vaults` declaration
      #   max_cost: a hard spend cap in dollars
      def start(message = nil, subject: nil, owner: nil, vaults: default_vaults, title: nil, metadata: nil,
        resources: nil, max_cost: nil, pin_version: true, run: true)
        version = agent_version if pin_version
        vault_ids = vault_chain(vaults, owner: owner).remote_ids
        params = {
          agent: version ? {type: "agent", id: agent_id, version: version} : agent_id,
          environment_id: environment_id,
          title: title,
          metadata: metadata&.transform_values(&:to_s),
          resources: resources,
          vault_ids: vault_ids.presence,
          budget: max_cost && {type: "limit", max_list_cost: {amount: (max_cost * 100).round.to_s, currency: "USD"}}
        }.compact

        remote = ManagedAgents.client.beta.sessions.create(**params)
        session = Session.create!(
          remote_id: remote.id,
          agent_name: definition.name,
          agent_version: version,
          subject: subject,
          owner: owner,
          vault_ids: vault_ids,
          title: title,
          metadata: metadata
        )
        # Sent as its own event rather than with the create call: the response
        # carries the event's ID, so the message is in the transcript at once.
        session.send_message(message, run: run) if message
        session
      end

      # Fires one of this agent's scheduled deployments now.
      def run_deployment(key)
        Deployments.run(definition.name, key.to_s)
      end
    end

    attr_reader :session

    def initialize(session)
      @session = session
    end

    def subject = session.subject

    def owner = session.owner

    def call_tool(name, input)
      handler = tools[name.to_s]
      return Tool.error("No handler is registered for the #{name} tool") unless handler

      schema = self.class.definition.custom_tool(name)&.dig("input_schema")
      problems = Schema.problems(input, schema)
      return Tool.error("Invalid input: #{problems.join("; ")}") if problems.any?

      Tool.result(instance_exec(input.with_indifferent_access, &handler))
    rescue ToolError => error
      Tool.error(error.message)
    rescue => error
      report(error, tool: name)
      Tool.error("#{name} failed: #{error.class}: #{error.message}")
    end

    def turn_finished
      run_callbacks(turn_callbacks)
    end

    def errored(event)
      run_callbacks(error_callbacks, event)
    end

    private

    def run_callbacks(callbacks, *args)
      callbacks.each do |callback|
        callback.is_a?(Proc) ? instance_exec(*args, &callback) : send(callback, *args.first(method(callback).arity.abs))
      rescue => error
        report(error, callback: callback.to_s)
      end
    end

    def report(error, **context)
      ManagedAgents.logger.error("[managed_agents] #{error.class}: #{error.message}")
      Rails.error.report(error, handled: true, context: {session: session.remote_id, **context})
    end
  end
end

require "managed_agents"

module ManagedAgents
  # An in-memory stand-in for the Anthropic client, for your app's tests:
  #
  #   class TicketTriageTest < ActiveSupport::TestCase
  #     include ManagedAgents::Testing::Helper
  #
  #     test "sets the priority" do
  #       sync_agents
  #       anthropic.respond_with custom_tool_use("set_priority", priority: "high"), agent_message("Done"), idle
  #
  #       session = SupportTriageAgent.start("Triage", subject: tickets(:one), run: false)
  #       session.run_now
  #
  #       assert_equal "high", tickets(:one).reload.priority
  #     end
  #   end
  module Testing
    # Response objects: hash data with reader methods, like the SDK's models.
    class Record
      def initialize(attributes = {})
        @attributes = attributes.deep_symbolize_keys
      end

      def [](key) = @attributes[key.to_sym]

      def to_h = @attributes

      def to_json(*) = @attributes.to_json(*)

      def merge!(attributes)
        @attributes.merge!(attributes.deep_symbolize_keys)
        self
      end

      def respond_to_missing?(name, include_private = false)
        @attributes.key?(name) || super
      end

      def method_missing(name, *args)
        return super unless args.empty? && !name.end_with?("=", "!")

        value = @attributes[name]
        value.is_a?(Hash) ? Record.new(value) : value
      end
    end

    class Page
      attr_reader :data

      def initialize(data) = @data = data

      def auto_paging_each(&block)
        raise ArgumentError, "A block must be given to #auto_paging_each" unless block

        data.each(&block)
      end
    end

    # Builders for session events. IDs are assigned in order.
    module EventBuilders
      def user_message(text) = build_event("user.message", content: [{type: "text", text: text}])

      def agent_message(text) = build_event("agent.message", content: [{type: "text", text: text}])

      def custom_tool_use(name, input = {}) = build_event("agent.custom_tool_use", name: name.to_s, input: input)

      def tool_use(name, input = {}, permission: "allow")
        build_event("agent.tool_use", name: name.to_s, input: input, evaluated_permission: permission)
      end

      def tool_result(text, error: false)
        build_event("agent.tool_result", content: [{type: "text", text: text}], is_error: error)
      end

      def running = build_event("session.status_running")

      def idle(stop_reason = "end_turn") = build_event("session.status_idle", stop_reason: {type: stop_reason})

      def terminated = build_event("session.status_terminated")

      def session_error(message) = build_event("session.error", error: {message: message})

      def build_event(type, **attributes)
        {id: Testing.next_id("sevt"), type: type, **attributes}
      end
    end

    class Collection
      attr_reader :records

      def initialize(client, prefix, versioned: false, unique_name: false)
        @client = client
        @prefix = prefix
        @versioned = versioned
        @unique_name = unique_name
        @records = {}
      end

      def create(**params)
        @client.calls << [:"#{@prefix}.create", params]
        if @unique_name && @records.each_value.any? { |record| record.name == params[:name] && record.archived_at.nil? }
          raise Testing.api_error(Anthropic::Errors::ConflictError, 409, "#{params[:name]} already exists")
        end

        store(Record.new(params.merge(id: Testing.next_id(@prefix), archived_at: nil).merge(@versioned ? {version: 1} : {})))
      end

      def update(id, **params)
        @client.calls << [:"#{@prefix}.update", {id: id, **params}]
        record = retrieve(id)
        params = params.except(:version).merge(version: record.version + 1) if @versioned
        record.merge!(params)
      end

      def retrieve(id, **)
        @records.fetch(id) { raise Testing.api_error(Anthropic::Errors::NotFoundError, 404, "#{id} not found") }
      end

      def list(**) = Page.new(@records.values)

      def archive(id, **)
        @client.calls << [:"#{@prefix}.archive", {id: id}]
        retrieve(id).merge!(archived_at: Time.current.iso8601)
      end

      def store(record)
        @records[record.id] = record
      end
    end

    class Credentials < Collection
      def create(vault_id, **params) = super(vault_id: vault_id, **params)

      def update(id, vault_id:, **params) = super(id, **params)

      def list(vault_id, **) = Page.new(@records.values.select { |record| record.vault_id == vault_id })

      def archive(id, vault_id:, **) = super(id)

      # What the next validations report: "valid", "invalid" or "unknown".
      attr_writer :validation_status

      def mcp_oauth_validate(id, vault_id:, **)
        @client.calls << [:"#{@prefix}.validate", {id: id}]
        Record.new(type: "vault_credential_validation", credential_id: id, vault_id: vault_id,
          status: @validation_status || "valid")
      end
    end

    class Vaults < Collection
      attr_reader :credentials

      def initialize(client)
        super(client, "vlt")
        @credentials = Credentials.new(client, "vcrd")
      end
    end

    class Deployments < Collection
      def run(id, **)
        @client.calls << [:"depl.run", {id: id}]
        deployment = retrieve(id)
        # A fired session starts with the deployment's kickoff events, as on the API.
        session = @client.beta.sessions.create(agent: deployment.agent, environment_id: deployment.environment_id,
          initial_events: deployment[:initial_events])
        @client.beta.deployment_runs.store(Record.new(id: Testing.next_id("drun"), deployment_id: id, session_id: session.id))
      end
    end

    class DeploymentRuns < Collection
      def list(deployment_id: nil, **)
        Page.new(@records.values.select { |record| deployment_id.nil? || record.deployment_id == deployment_id })
      end
    end

    class Stream
      def initialize(events, log)
        @events = events
        @log = log
      end

      # Hands over the scripted events, moving each into the session's history.
      def each
        while (event = @events.shift)
          raise event if event.is_a?(Exception)

          next yield(event) if event[:type].to_s.start_with?("event_")

          @log << Testing.stamp(event)
          yield event
        end
      end

      def close = nil
    end

    class SessionEvents
      def initialize(client)
        @client = client
      end

      def list(session_id, **) = Page.new(@client.history(session_id).each { |event| Testing.stamp(event) }.dup)

      def stream_events(session_id, **) = Stream.new(@client.queue(session_id), @client.history(session_id))

      def send_(session_id, events:, **)
        @client.calls << [:"sesn.events.send", {id: session_id, events: events}]
        sent = events.map do |event|
          event.deep_symbolize_keys.merge(id: Testing.next_id("sevt"), processed_at: Testing.timestamp)
        end
        @client.history(session_id).concat(sent)
        @client.sent_events.concat(sent)
        Record.new(data: sent)
      end
    end

    class Sessions < Collection
      attr_reader :events

      def initialize(client)
        super(client, "sesn")
        @events = SessionEvents.new(client)
      end

      def create(**params)
        session = super(**params, status: params[:initial_events].present? ? "running" : "idle")
        @events.send_(session.id, events: params[:initial_events]) if params[:initial_events].present?
        session
      end
    end

    # Uploaded files are recorded as their names; each upload is a new version.
    class SkillVersions
      def initialize(client) = @client = client

      def create(skill_id, files:, **)
        @client.calls << [:"skill.versions.create", {id: skill_id, files: Skills.names(files)}]
        version = Record.new(id: Testing.next_id("skillver"), skill_id: skill_id, type: "skill_version")
        latest = {latest_version_id: version.id}
        @client.beta.skills.retrieve(skill_id).merge!(latest)
        version
      end
    end

    class Skills < Collection
      attr_reader :versions

      def self.names(files) = files.map { |file| file.try(:filename) || file.to_s }

      def initialize(client)
        super(client, "skill")
        @versions = SkillVersions.new(client)
      end

      def create(files:, **params)
        @client.calls << [:"skill.create", params.merge(files: Skills.names(files))]
        store(Record.new(params.merge(id: Testing.next_id("skill"), latest_version_id: Testing.next_id("skillver"), type: "skill")))
      end

      def delete(id, **)
        @client.calls << [:"skill.delete", {id: id}]
        @records.delete(id)
      end
    end

    class Webhooks
      # Signature checks are the SDK's job; the fake just parses the payload.
      def unwrap(payload, **)
        Record.new(JSON.parse(payload))
      end
    end

    class Beta
      attr_reader :agents, :environments, :vaults, :deployments, :deployment_runs, :sessions, :skills, :webhooks

      def initialize(client)
        @agents = Collection.new(client, "agent", versioned: true)
        @environments = Collection.new(client, "env", unique_name: true)
        @vaults = Vaults.new(client)
        @deployments = Deployments.new(client, "depl")
        @deployment_runs = DeploymentRuns.new(client, "drun")
        @sessions = Sessions.new(client)
        @skills = Skills.new(client)
        @webhooks = Webhooks.new
      end
    end

    class FakeClient
      attr_reader :beta, :calls, :sent_events

      def initialize
        @calls = []
        @sent_events = []
        @queues = Hash.new { |queues, id| queues[id] = [] }
        @histories = Hash.new { |histories, id| histories[id] = [] }
        @beta = Beta.new(self)
      end

      # Events the next stream connection will deliver. Without `session`, they
      # go to whichever session is followed next.
      def respond_with(*events, session: nil)
        queue(session&.remote_id || :next).concat(events.flatten)
      end

      def queue(session_id)
        pending = @queues.delete(:next)
        @queues[session_id].concat(pending) if pending && session_id != :next
        @queues[session_id]
      end

      def history(session_id) = @histories[session_id]

      def calls_to(name) = calls.select { |call, _| call == name }.map(&:last)

      def tool_results
        sent_events.select { |event| event[:type] == "user.custom_tool_result" }
      end
    end

    module Helper
      extend ActiveSupport::Concern
      include EventBuilders

      included do
        setup { @anthropic = ManagedAgents.config.client = FakeClient.new }
        teardown { ManagedAgents.config.client = nil }
      end

      def anthropic = @anthropic

      # Fills the resources table as `managed_agents:sync` would, using the fake.
      def sync_agents(**)
        Sync.new(backend: :api, io: StringIO.new, **).apply
      end
    end

    class << self
      def next_id(prefix)
        @sequence = @sequence.to_i + 1
        format("%s_%06d", prefix, @sequence)
      end

      # Event times with the sub-second precision the API uses.
      def timestamp
        Time.current.iso8601(6)
      end

      # Events get their time when the fake delivers them, in delivery order,
      # as the API stamps events when it processes them. An explicit
      # `processed_at: nil` (a queued event) is left alone.
      def stamp(event)
        event[:processed_at] = timestamp unless event.key?(:processed_at)
        event
      end

      def api_error(klass, status, message)
        klass.new(url: URI("https://api.anthropic.com"), status: status, headers: {}, body: nil,
          request: nil, response: nil, message: message)
      end
    end
  end
end

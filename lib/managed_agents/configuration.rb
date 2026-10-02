module ManagedAgents
  class Configuration
    # Directory holding one folder per agent, relative to Rails.root.
    attr_accessor :agents_path

    # An Anthropic::Client, or a callable returning one. Leave nil to let the
    # engine build a single shared client.
    attr_accessor :client

    # Defaults to ENV["ANTHROPIC_API_KEY"], then credentials.anthropic.api_key,
    # then whatever the SDK resolves on its own (ant profile, workload identity).
    attr_accessor :api_key

    # Used to detect a database that was synced against another workspace and
    # to build Console links. Defaults to ENV["ANTHROPIC_WORKSPACE_ID"].
    attr_writer :workspace_id

    # :auto, :ant or :api. See ManagedAgents::Sync.
    attr_accessor :sync_backend

    attr_accessor :ant_bin

    # Signing secret (whsec_...) for the webhook endpoint.
    attr_writer :webhook_secret

    attr_accessor :queue

    # Parent class for the engine's models, as a string.
    attr_accessor :record_base_class

    # Seconds one stream connection is held before the runner re-attaches. The
    # SDK timeout is an absolute deadline, so long turns need several windows.
    attr_accessor :stream_window

    # Seconds a SessionJob keeps following one session before giving up.
    attr_accessor :max_run_time

    # Base delay in seconds before reconnecting a dropped stream; it doubles
    # with each consecutive failure.
    attr_accessor :reconnect_delay

    # Broadcast events over Turbo Streams when turbo-rails is present.
    attr_accessor :broadcast

    # Stream partial assistant text to the page while the model is writing.
    attr_accessor :stream_deltas

    # Optional callable turning an agent message into HTML, for example
    # ->(text) { Commonmarker.to_html(text) }. The result is not escaped.
    attr_accessor :markdown

    attr_accessor :logger

    def initialize
      @agents_path = "app/agents"
      @sync_backend = :auto
      @ant_bin = "ant"
      @queue = :default
      @record_base_class = "ApplicationRecord"
      @stream_window = 300
      @max_run_time = 1800
      @reconnect_delay = 0.5
      @broadcast = true
      @stream_deltas = true
    end

    def workspace_id
      @workspace_id || ENV["ANTHROPIC_WORKSPACE_ID"].presence
    end

    def webhook_secret
      @webhook_secret || ENV["ANTHROPIC_WEBHOOK_SIGNING_KEY"].presence ||
        Secrets.lookup("anthropic.webhook_secret")
    end

    def agents_root
      Rails.root.join(agents_path)
    end
  end
end

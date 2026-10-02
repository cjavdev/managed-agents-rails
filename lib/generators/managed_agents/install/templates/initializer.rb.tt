ManagedAgents.configure do |config|
  # The API key is read from ENV["ANTHROPIC_API_KEY"], then from
  # credentials.anthropic.api_key. With neither set, the SDK falls back to an
  # `ant auth login` profile or workload identity federation.
  # config.api_key = Rails.application.credentials.dig(:anthropic, :api_key)

  # Guards against syncing a database into the wrong workspace, and is used to
  # build links to the Claude Console. Defaults to ENV["ANTHROPIC_WORKSPACE_ID"].
  # config.workspace_id = "wrkspc_..."

  # :auto uses `ant apply` when the CLI is installed and the API otherwise.
  # config.sync_backend = :auto

  # Signing secret for webhooks, from Console > Manage > Webhooks. The endpoint
  # is POST /managed_agents/webhooks.
  # config.webhook_secret = Rails.application.credentials.dig(:anthropic, :webhook_secret)

  # Session jobs hold a stream for as long as the agent works. Give them a
  # queue with threads to spare.
  # config.queue = :agents

  # Render agent messages as Markdown. The result is inserted as HTML.
  # config.markdown = ->(text) { Commonmarker.to_html(text) }
end

require "anthropic"

require "managed_agents/version"
require "managed_agents/errors"
require "managed_agents/configuration"
require "managed_agents/secrets"
require "managed_agents/has_agent_sessions"
require "managed_agents/mcp"
require "managed_agents/credential_auth"
require "managed_agents/vault_chain"
require "managed_agents/agent_vault"
require "managed_agents/document"
require "managed_agents/definition"
require "managed_agents/schema"
require "managed_agents/tool"
require "managed_agents/agent"
require "managed_agents/events"
require "managed_agents/runner"
require "managed_agents/sync"
require "managed_agents/deployments"
require "managed_agents/oauth"
require "managed_agents/engine"

module ManagedAgents
  CLIENT_MUTEX = Mutex.new
  private_constant :CLIENT_MUTEX

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # One client per process. Workload identity tokens are single use, so
    # building a client per call makes concurrent exchanges fail.
    def client
      configured = config.client
      return configured.respond_to?(:call) ? configured.call : configured if configured

      CLIENT_MUTEX.synchronize { @client ||= build_client }
    end

    def reset_client!
      CLIENT_MUTEX.synchronize { @client = nil }
    end

    def secret(path)
      Secrets.fetch(path)
    end

    def definitions
      Definition.all
    end

    def definition(name)
      Definition.find(name)
    end

    # The agent class for a directory under app/agents: SupportTriageAgent for
    # "support_triage" when the app defines one, otherwise a plain agent.
    def agent(name)
      Agent.for(name)
    end

    def sync(**)
      Sync.new(**).apply
    end

    def logger
      config.logger || (defined?(Rails) && Rails.logger) || Logger.new($stdout)
    end

    private

    def build_client
      options = {
        api_key: config.api_key || Secrets.lookup("anthropic.api_key"),
        webhook_key: config.webhook_secret
      }.compact
      Anthropic::Client.new(**options)
    end
  end
end

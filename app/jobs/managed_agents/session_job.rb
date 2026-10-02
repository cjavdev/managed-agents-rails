module ManagedAgents
  # Holds a session's event stream until the agent's turn settles. Run these on
  # a queue with spare threads: a job lasts as long as the turn does.
  class SessionJob < ApplicationJob
    RETRIES_WHILE_BUSY = 12

    # Nothing is lost by starting over: the runner reads the event history and
    # answers whatever is still pending.
    retry_on Anthropic::Errors::APIConnectionError, Anthropic::Errors::RateLimitError,
      Anthropic::Errors::InternalServerError, wait: :polynomially_longer, attempts: 5

    def perform(session, attempt = 0)
      case Runner.new(session).run
      when :continue
        self.class.perform_later(session)
      when :busy
        # Another job is following the session. Check back in case it settles
        # just before something new arrives.
        self.class.set(wait: 5.seconds).perform_later(session, attempt + 1) if attempt < RETRIES_WHILE_BUSY
      when :stalled
        ManagedAgents.logger.warn("[managed_agents] Session #{session.remote_id} produced no events; stopped following it")
      end
    end
  end
end

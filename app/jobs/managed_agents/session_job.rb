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
        if attempt < RETRIES_WHILE_BUSY
          self.class.set(wait: 5.seconds).perform_later(session, attempt + 1)
        elsif attempt == RETRIES_WHILE_BUSY && (expires = session.reload.lease_expires_at)
          # A follower that died with its process (a deploy's restart) keeps the
          # lease until it runs out, long after the quick checks above give up.
          # One last look then: a live follower has renewed it, a dead one hasn't.
          self.class.set(wait: [expires - Time.current, 0].max + 1.second).perform_later(session, attempt + 1)
        end
      when :stalled
        ManagedAgents.logger.warn("[managed_agents] Session #{session.remote_id} produced no events; stopped following it")
      end
    end
  end
end

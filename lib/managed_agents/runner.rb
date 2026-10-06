require "securerandom"

module ManagedAgents
  # Follows one session until its turn settles: persists every event, answers
  # custom tool calls with the agent's handlers and runs its callbacks.
  #
  # The event stream has no replay, so every connection opens the stream first
  # and then reads the full event list; events are deduplicated by ID when they
  # are recorded.
  class Runner
    RECONNECTS = 5
    PREVIEW_INTERVAL = 0.15

    attr_reader :session

    def initialize(session, client: ManagedAgents.client)
      @session = session
      @client = client
      @token = SecureRandom.hex(8)
    end

    # Returns :done when the turn settled, :continue when the time limit ran out
    # first, :busy when another runner is already following the session, and
    # :stalled when the stream keeps closing with nothing new to read.
    def run
      return :busy unless lease

      deadline = now + config.max_run_time
      failures = 0

      loop do
        enforce_turn_deadline
        seen = session.events.count
        return finished if follow == :done
        return :continue if now > deadline

        # The stream closed without the turn ending. Back off rather than
        # reconnect in a tight loop, and give up if nothing ever arrives.
        failures = (session.events.count > seen) ? 0 : failures + 1
        return :stalled if failures > RECONNECTS
        pause(failures)
      rescue Anthropic::Errors::APITimeoutError
        return :continue if now > deadline
      rescue Anthropic::Errors::APIConnectionError
        raise if (failures += 1) > RECONNECTS
        pause(failures)
      ensure
        lease
      end
    ensure
      session.release_lease(@token)
    end

    private

    # The SDK's stream skips event types it doesn't know, usage among them, so
    # the totals are read from the session once the turn is over.
    def finished
      begin
        remote = @client.beta.sessions.retrieve(session.remote_id)
        usage = remote.try(:usage)
        session.update!(usage: Events.to_hash(usage)) if usage
      rescue Anthropic::Errors::APIError
        nil
      end
      archive if agent.archive_after_turn && session.settled? && session.archived_at.nil?
      :done
    end

    def archive
      session.archive!
    rescue Anthropic::Errors::APIError => error
      ManagedAgents.logger.warn("[managed_agents] could not archive #{session.remote_id}: #{error.message}")
    end

    # Interrupts a turn that has run past the agent's max_turn_duration.
    def enforce_turn_deadline
      deadline = agent.turn_deadline
      agent.interrupt!(:deadline) if deadline && Time.current >= deadline && !session.settled?
    end

    # Seconds to hold the stream: the window, or less when the turn's deadline
    # comes first, so a stream waiting for events cannot sleep through it.
    def stream_timeout
      deadline = agent.turn_deadline
      return config.stream_window if deadline.nil? || agent.interrupted?

      (deadline - Time.current).ceil.clamp(1, config.stream_window)
    end

    def follow
      stream = open_stream
      backfill
      answer_pending
      return :done if done?

      stream.each do |raw|
        return :done if handle(raw) == :done
      end
      done? ? :done : :ended
    ensure
      stream.close if stream.respond_to?(:close)
    end

    def open_stream
      params = {request_options: {timeout: stream_timeout, max_retries: 0}}
      params[:event_deltas] = [:"agent.message"] if config.stream_deltas
      @client.beta.sessions.events.stream_events(session.remote_id, **params)
    end

    def backfill
      @client.beta.sessions.events.list(session.remote_id, order: :asc).auto_paging_each do |raw|
        dispatch(session.record(raw), live: false)
      end
    end

    def handle(raw)
      payload = Events.to_hash(raw)
      return preview(payload) if Events.preview?(payload)

      event = session.record(payload)
      dispatch(event, live: true)
      enforce_turn_deadline
      :done if event&.status? && done?
    end

    def dispatch(event, live:)
      return unless event

      agent.event_received(event)
      case event.event_type
      when "agent.custom_tool_use"
        answer(event) if live
      when "session.status_idle"
        agent.turn_finished unless event.stop_reason == "requires_action"
      when "session.error"
        agent.errored(event)
      end
    end

    def answer_pending
      session.pending_tool_uses.each { |event| answer(event) }
    end

    def answer(event)
      result = agent.call_tool(event.tool_name, event.tool_input, tool_use_id: event.remote_id)
      response = @client.beta.sessions.events.send_(session.remote_id,
        events: [Events.custom_tool_result(event.remote_id, result)])
      Array(response.try(:data)).each { |sent| session.record(sent) }
    end

    def preview(payload)
      case payload["type"]
      when "event_start"
        @preview = +""
      when "event_delta"
        (@preview ||= +"") << payload.dig("delta", "content", "text").to_s
        if now - @previewed_at.to_f >= PREVIEW_INTERVAL
          @previewed_at = now
          Broadcasts.preview(session, @preview.dup)
        end
      end
      nil
    end

    def done?
      session.reload
      session.settled? || session.awaiting_confirmation? || session.events.none?
    end

    def agent
      @agent ||= session.agent_class.new(session)
    end

    def lease
      session.acquire_lease(@token, ttl: config.stream_window + 120)
    end

    def pause(attempt)
      sleep(config.reconnect_delay * 2**attempt) if attempt.positive? && config.reconnect_delay.positive?
    end

    def config = ManagedAgents.config

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

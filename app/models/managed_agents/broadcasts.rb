module ManagedAgents
  # Turbo Stream broadcasts for the chat UI. A no-op without turbo-rails.
  module Broadcasts
    module_function

    def enabled?
      ManagedAgents.config.broadcast && defined?(Turbo::StreamsChannel)
    end

    def event(event)
      return unless enabled? && event.visible?

      session = event.session
      Turbo::StreamsChannel.broadcast_append_to(session, target: session.events_dom_id,
        partial: "managed_agents/events/event", locals: {event: event})
      preview(session, "") if event.event_type == "agent.message"
    end

    def status(session)
      return unless enabled?

      Turbo::StreamsChannel.broadcast_replace_to(session, target: session.status_dom_id,
        partial: "managed_agents/sessions/status", locals: {agent_session: session})
    end

    # Partial assistant text while the model is still writing.
    def preview(session, text)
      return unless enabled?

      Turbo::StreamsChannel.broadcast_update_to(session, target: session.preview_dom_id,
        partial: "managed_agents/events/preview", locals: {text: text})
    end
  end
end

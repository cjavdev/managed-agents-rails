require "json"

module ManagedAgents
  # Session events arrive as SDK model objects from the stream and the event
  # list. Everything past this module works with plain string-keyed hashes.
  module Events
    PREVIEWS = %w[event_start event_delta].freeze

    module_function

    def to_hash(raw)
      raw.is_a?(Hash) ? raw.deep_stringify_keys.then { |hash| JSON.parse(hash.to_json) } : JSON.parse(raw.to_json)
    end

    def normalize(raw)
      payload = to_hash(raw)
      {
        remote_id: payload["id"],
        event_type: payload["type"].to_s,
        payload: payload,
        processed_at: payload["processed_at"]
      }
    end

    def preview?(payload)
      payload["type"].to_s.in?(PREVIEWS)
    end

    def user_message(text)
      {type: "user.message", content: [{type: "text", text: text.to_s}]}
    end

    def custom_tool_result(event_id, result)
      {
        type: "user.custom_tool_result",
        custom_tool_use_id: event_id,
        content: [{type: "text", text: result.text}],
        is_error: result.error?
      }
    end
  end
end

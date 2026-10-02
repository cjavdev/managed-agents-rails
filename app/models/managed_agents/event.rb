module ManagedAgents
  class Event < ApplicationRecord
    belongs_to :session, inverse_of: :events

    validates :remote_id, :event_type, presence: true

    after_create_commit -> { Broadcasts.event(self) }

    def payload
      super || {}
    end

    def user? = event_type.start_with?("user.")

    def agent? = event_type.start_with?("agent.")

    def status? = event_type.start_with?("session.status_")

    def tool_use? = event_type.in?(%w[agent.tool_use agent.mcp_tool_use agent.custom_tool_use])

    def tool_result? = event_type.in?(%w[agent.tool_result agent.mcp_tool_result user.custom_tool_result])

    # Text of a message or tool result, joined across content blocks.
    def text
      Array(payload["content"]).filter_map { |block| block["text"] if block.is_a?(Hash) }.join("\n").presence
    end

    def tool_name = payload["name"]

    def tool_input
      payload["input"] || {}
    end

    def stop_reason
      payload.dig("stop_reason", "type")
    end

    def error_message
      payload.dig("error", "message")
    end

    def error? = event_type == "session.error" || payload["is_error"] == true

    def awaiting_confirmation?
      payload["evaluated_permission"] == "ask" && session.pending_confirmations.include?(self)
    end

    # The partial used to render this event: "agent.tool_use" -> "tool_use".
    def partial_name
      case event_type
      when "user.message" then "user_message"
      when "agent.message" then "agent_message"
      when "agent.tool_use", "agent.mcp_tool_use", "agent.custom_tool_use" then "tool_use"
      when "agent.tool_result", "agent.mcp_tool_result", "user.custom_tool_result" then "tool_result"
      when "session.error" then "error"
      when "session.status_idle", "session.status_terminated" then "status"
      end
    end

    def visible? = !partial_name.nil?

    def dom_id = "managed_agents_event_#{id}"
  end
end

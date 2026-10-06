module ManagedAgents
  class Session < ApplicationRecord
    MARKERS = %w[
      user.message user.custom_tool_result user.tool_confirmation user.tool_result user.define_outcome
      session.status_running session.status_rescheduled session.status_idle session.status_terminated
    ].freeze

    belongs_to :subject, polymorphic: true, optional: true
    belongs_to :owner, polymorphic: true, optional: true
    has_many :events, -> { order(:id) }, dependent: :delete_all, inverse_of: :session

    validates :remote_id, :agent_name, presence: true

    scope :recent, -> { order(created_at: :desc) }
    scope :for_agent, ->(name) { where(agent_name: name.to_s) }
    scope :owned_by, ->(owner) { where(owner: owner) }

    after_update_commit :broadcast_status, if: -> { saved_change_to_status? || saved_change_to_title? }

    def agent_class
      ManagedAgents.agent(agent_name)
    end

    def send_message(text, run: true)
      deliver({type: "user.message", content: [{type: "text", text: text.to_s}]})
      update!(status: "running") unless terminated?
      run_later if run
      self
    end

    def interrupt!(run: true)
      deliver({type: "user.interrupt"})
      run_later if run
      self
    end

    # Answers a tool call that paused for approval.
    def confirm_tool(event, allow:, message: nil)
      confirmation = {type: "user.tool_confirmation", tool_use_id: event.remote_id, result: allow ? "allow" : "deny"}
      confirmation[:deny_message] = message if message.present? && !allow
      deliver(confirmation)
      update!(status: "running")
      run_later
      self
    end

    def deliver(*events)
      response = ManagedAgents.client.beta.sessions.events.send_(remote_id, events: events)
      Array(response.try(:data)).each { |event| record(event) }
      response
    end

    def run_later
      SessionJob.perform_later(self)
    end

    # Follows the session in this process until the turn settles.
    def run_now
      Runner.new(self).run
    end

    # Stores an event from the stream or the event list. Returns the new record,
    # or nil when the event was already known.
    def record(raw)
      attributes = Events.normalize(raw)
      return if attributes[:remote_id].blank?

      if (existing = events.find_by(remote_id: attributes[:remote_id]))
        existing.update!(attributes.slice(:payload, :processed_at)) if existing.processed_at.nil? && attributes[:processed_at]
        return
      end

      event = events.create!(attributes)
      apply(event)
      event
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def running? = status.in?(%w[running rescheduling])

    def terminated? = status == "terminated"

    def requires_action? = status == "requires_action"

    # True once the last thing that happened is the agent finishing (or the
    # session ending), with nothing sent to it since.
    def settled?
      marker = last_marker
      return false unless marker

      marker.event_type == "session.status_terminated" ||
        (marker.event_type == "session.status_idle" && marker.stop_reason != "requires_action")
    end

    # Custom tool calls the app still has to answer.
    def pending_tool_uses
      answered = events.where(event_type: "user.custom_tool_result").map { |event| event.payload["custom_tool_use_id"] }
      events.where(event_type: "agent.custom_tool_use").reject { |event| event.remote_id.in?(answered) }
    end

    # Built-in or MCP tool calls waiting for a person to allow or deny them.
    def pending_confirmations
      confirmed = events.where(event_type: "user.tool_confirmation").map { |event| event.payload["tool_use_id"] }
      events.where(event_type: %w[agent.tool_use agent.mcp_tool_use])
        .select { |event| event.payload["evaluated_permission"] == "ask" }
        .reject { |event| event.remote_id.in?(confirmed) }
    end

    def awaiting_confirmation?
      marker = last_marker
      marker&.event_type == "session.status_idle" && marker.stop_reason == "requires_action" &&
        pending_tool_uses.empty? && pending_confirmations.any?
    end

    # When the current turn began: the last message sent to the agent.
    def turn_started_at
      message = events.where(event_type: "user.message").last
      message&.processed_at || message&.created_at || created_at
    end

    def last_agent_message
      events.where(event_type: "agent.message").last&.text
    end

    def list_cost
      amount = usage&.dig("list_cost", "amount")
      amount && amount.to_i / 100.0
    end

    def console_url
      workspace = ManagedAgents.config.workspace_id || "default"
      "https://platform.claude.com/workspaces/#{workspace}/sessions/#{remote_id}"
    end

    def archive!
      ManagedAgents.client.beta.sessions.archive(remote_id)
      update!(archived_at: Time.current)
    end

    def acquire_lease(token, ttl:)
      now = Time.current
      self.class.where(id: id)
        .where("lease_expires_at IS NULL OR lease_expires_at < ? OR lease_token = ?", now, token)
        .update_all(lease_token: token, lease_expires_at: now + ttl) == 1
    end

    def release_lease(token)
      self.class.where(id: id, lease_token: token).update_all(lease_token: nil, lease_expires_at: nil)
    end

    def events_dom_id = "managed_agents_session_#{id}_events"

    def preview_dom_id = "managed_agents_session_#{id}_preview"

    def status_dom_id = "managed_agents_session_#{id}_status"

    private

    # The most recent turn marker in the order the session processed them. A
    # message sent while the agent was busy is still queued (no processed_at)
    # when the earlier turn's idle arrives, and has to count as newer than it.
    def last_marker
      events.where(event_type: MARKERS)
        .reorder(Arel.sql("CASE WHEN processed_at IS NULL THEN 1 ELSE 0 END"), :processed_at, :id).last
    end

    def apply(event)
      case event.event_type
      when "session.status_running" then update!(status: "running", stop_reason: nil)
      when "session.status_rescheduled" then update!(status: "rescheduling")
      when "session.status_terminated" then update!(status: "terminated")
      when "session.status_idle"
        reason = event.stop_reason
        update!(status: (reason == "requires_action") ? "requires_action" : "idle", stop_reason: reason)
      when "session.usage"
        update!(usage: event.payload["usage"] || event.payload.except("id", "type", "processed_at"))
      end
    end

    def broadcast_status
      Broadcasts.status(self)
    end
  end
end

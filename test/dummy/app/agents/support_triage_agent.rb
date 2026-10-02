class SupportTriageAgent < ApplicationAgent
  tool :set_priority do |input|
    raise ManagedAgents::ToolError, "There is no ticket to update" unless subject

    subject.update!(priority: input[:priority])
    {ok: true, priority: subject.priority}
  end

  after_turn do
    subject&.update!(summary: session.last_agent_message)
  end
end

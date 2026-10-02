# Shared behaviour for the agents in this folder. Each agent is defined by the
# files in app/agents/<name>/; add app/agents/<name>_agent.rb when it needs
# custom tool handlers or callbacks.
class ApplicationAgent < ManagedAgents::Agent
end

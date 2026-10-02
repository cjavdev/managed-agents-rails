module ManagedAgents
  class Error < StandardError; end

  # A definition file is missing, unparsable, or refers to something that isn't there.
  class DefinitionError < Error; end

  # A `{credential: ...}` or `{env: ...}` reference could not be resolved.
  class MissingSecret < Error; end

  # The agent has not been synced into this database's workspace yet.
  class NotSynced < Error
    def initialize(name, kind = :agent)
      super("#{kind} for #{name.inspect} has not been synced. Run `bin/rails managed_agents:sync`.")
    end
  end

  # The stored IDs belong to a different workspace than the current credentials.
  class WorkspaceMismatch < Error; end

  class SyncError < Error; end

  # The remote resource changed outside of the definition files.
  class Drift < SyncError; end

  # Raise from a tool handler to return an error result to the agent.
  class ToolError < Error; end
end

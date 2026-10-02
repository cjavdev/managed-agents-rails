module ManagedAgents
  # A remote object created from a definition file: the ID lives here, not in
  # the repo, so every database (and so every workspace) has its own.
  class Resource < ApplicationRecord
    KINDS = %w[environment vault credential agent deployment].freeze

    validates :agent_name, :remote_id, presence: true
    validates :kind, inclusion: {in: KINDS}

    scope :for_agent, ->(name) { where(agent_name: name.to_s) }
    scope :of_kind, ->(kind) { where(kind: kind.to_s) }

    def self.lookup(agent_name, kind, key = "")
      find_by(agent_name: agent_name.to_s, kind: kind.to_s, key: key.to_s)
    end

    def self.remote_id!(agent_name, kind, key = "")
      lookup(agent_name, kind, key)&.remote_id || raise(NotSynced.new(agent_name, kind))
    end

    # Saved straight away so a crash halfway through a sync never loses an ID.
    def self.record!(agent_name:, kind:, key: "", **attributes)
      resource = find_or_initialize_by(agent_name: agent_name.to_s, kind: kind.to_s, key: key.to_s)
      resource.update!(synced_at: Time.current, **attributes)
      resource
    end

    def self.workspace_ids
      where.not(workspace_id: nil).distinct.pluck(:workspace_id)
    end
  end
end

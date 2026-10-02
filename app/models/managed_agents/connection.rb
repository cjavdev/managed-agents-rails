module ManagedAgents
  # One credential in an owner's vault: an MCP server someone connected, or a
  # secret exposed as an environment variable. Only what identifies it is kept
  # here; the secret itself lives in the vault and can't be read back.
  class Connection < ApplicationRecord
    KINDS = %w[mcp_oauth static_bearer environment_variable].freeze

    belongs_to :vault

    validates :key, :remote_id, presence: true
    validates :kind, inclusion: {in: KINDS}

    scope :usable, -> { where(status: "active") }

    before_destroy :archive_remote

    def usable? = status == "active"

    def needs_reauthorization? = status == "needs_reauthorization"

    def mcp? = kind != "environment_variable"

    def details
      super || {}
    end

    # The fields that can't change on an existing credential.
    def structure
      details.slice("type", *CredentialAuth::IMMUTABLE, *CredentialAuth::IMMUTABLE_REFRESH)
    end

    # Asks the API whether an OAuth credential still works, after a refresh
    # failure. Only a definite "invalid" means the person has to reconnect;
    # a transient error leaves the connection alone.
    def check!
      validation = ManagedAgents.client.beta.vaults.credentials.mcp_oauth_validate(remote_id, vault_id: vault.remote_id)
      case validation.status.to_s
      when "invalid" then update!(status: "needs_reauthorization")
      when "valid" then update!(status: "active")
      end
      self
    end

    private

    def archive_remote
      ManagedAgents.client.beta.vaults.credentials.archive(remote_id, vault_id: vault.remote_id)
    rescue Anthropic::Errors::NotFoundError
      nil
    end
  end
end

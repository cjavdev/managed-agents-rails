class User < ApplicationRecord
  belongs_to :account, optional: true
  has_agent_sessions as: :owner
  has_agent_vault
end

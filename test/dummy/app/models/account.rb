class Account < ApplicationRecord
  has_many :users
  has_agent_vault
end

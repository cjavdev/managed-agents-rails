class DailyDigest < ApplicationRecord
  validates :body, presence: true

  def self.latest = order(:created_at).last
end

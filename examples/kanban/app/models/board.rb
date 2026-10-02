class Board < ApplicationRecord
  DEFAULT_LISTS = ["To do", "Doing", "Done"].freeze

  has_many :lists, -> { order(:position) }, dependent: :destroy
  has_many :cards, through: :lists
  has_agent_sessions dependent: :destroy

  validates :name, presence: true

  after_create :create_default_lists

  # The conversation with the assistant carries on until its session ends.
  def assistant_session
    agent_sessions.where.not(status: "terminated").order(:id).last
  end

  def list_named(name)
    lists.find { |list| list.name.casecmp?(name.to_s.strip) }
  end

  # Redraws the columns for everyone looking at the board, whoever changed it.
  def broadcast_lists
    Turbo::StreamsChannel.broadcast_replace_to(self, :lists, target: "board_lists",
      partial: "boards/lists", locals: {board: self})
  end

  private

  def create_default_lists
    DEFAULT_LISTS.each_with_index { |name, position| lists.create!(name: name, position: position) }
  end
end

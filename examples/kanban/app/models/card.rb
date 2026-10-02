class Card < ApplicationRecord
  belongs_to :list
  has_one :board, through: :list

  validates :title, presence: true

  before_create { self.position = list.cards.maximum(:position).to_i + 1 }
  after_commit { list.board.broadcast_lists }

  def move_to(destination)
    update!(list: destination, position: destination.cards.maximum(:position).to_i + 1)
  end
end

class List < ApplicationRecord
  belongs_to :board
  has_many :cards, -> { order(:position) }, dependent: :destroy

  validates :name, presence: true

  def previous_list = board.lists.where(position: ...position).last

  def next_list = board.lists.where("position > ?", position).first
end

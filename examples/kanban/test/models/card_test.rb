require "test_helper"

class CardTest < ActiveSupport::TestCase
  setup { @board = Board.create!(name: "Launch") }

  test "a new board has the default lists" do
    assert_equal ["To do", "Doing", "Done"], @board.lists.map(&:name)
  end

  test "cards are added to the bottom of their list" do
    list = @board.list_named("to do")
    first = list.cards.create!(title: "First")
    second = list.cards.create!(title: "Second")

    assert_equal [first, second], list.cards.reload.to_a
  end

  test "moving a card puts it at the bottom of the destination" do
    doing = @board.list_named("Doing")
    existing = doing.cards.create!(title: "Already here")
    card = @board.list_named("To do").cards.create!(title: "Moving")

    card.move_to(doing)

    assert_equal [existing, card], doing.cards.reload.to_a
  end
end

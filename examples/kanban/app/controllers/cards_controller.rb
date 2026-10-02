class CardsController < ApplicationController
  def create
    list = List.find(params[:list_id])
    list.cards.create!(params.expect(card: [:title]))
    redirect_to list.board
  end

  # Moving a card is an update of its list.
  def update
    card = Card.find(params[:id])
    card.move_to(card.board.lists.find(params[:list_id]))
    redirect_to card.board
  end

  def destroy
    card = Card.find(params[:id])
    card.destroy!
    redirect_to card.board
  end
end

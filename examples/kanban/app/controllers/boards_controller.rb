class BoardsController < ApplicationController
  def index
    @boards = Board.order(:name)
  end

  def show
    @board = Board.find(params[:id])
    @session = @board.assistant_session
  end

  def create
    board = Board.create!(params.expect(board: [:name]))
    redirect_to board
  end
end

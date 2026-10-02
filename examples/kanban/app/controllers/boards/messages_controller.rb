# Messages to the board's assistant. The first one starts a session with the
# board as its subject; later ones continue that session.
class Boards::MessagesController < ApplicationController
  def create
    board = Board.find(params[:board_id])
    message = params.require(:message)

    if (agent_session = board.assistant_session)
      agent_session.send_message(message)
      respond_to do |format|
        # The transcript updates over the board's Turbo Stream.
        format.turbo_stream { head :no_content }
        format.html { redirect_to board }
      end
    else
      BoardAssistantAgent.start(message, subject: board, title: board.name)
      redirect_to board
    end
  rescue ManagedAgents::Error, Anthropic::Errors::Error => error
    redirect_to board, alert: error.message
  end
end

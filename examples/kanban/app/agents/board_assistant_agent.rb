# Ruby side of app/agents/board_assistant/. The session's subject is the board.
class BoardAssistantAgent < ApplicationAgent
  tool :list_cards do |_input|
    board.lists.includes(:cards).map do |list|
      {list: list.name, cards: list.cards.map { |card| card.slice(:id, :title, :description) }}
    end
  end

  tool :create_card do |input|
    list = find_list(input[:list])
    card = list.cards.create!(title: input[:title], description: input[:description])
    {id: card.id, list: list.name, title: card.title}
  end

  tool :move_card do |input|
    card = find_card(input[:card_id])
    card.move_to(find_list(input[:list]))
    {id: card.id, list: card.list.name}
  end

  tool :update_card do |input|
    card = find_card(input[:card_id])
    card.update!(input.slice(:title, :description))
    card.slice(:id, :title, :description)
  end

  private

  def board = subject

  def find_list(name)
    board.list_named(name) ||
      raise(ManagedAgents::ToolError, "There is no list called #{name.inspect}. Lists: #{board.lists.map(&:name).join(", ")}")
  end

  def find_card(id)
    board.cards.find_by(id: id) || raise(ManagedAgents::ToolError, "There is no card with id #{id} on this board")
  end
end

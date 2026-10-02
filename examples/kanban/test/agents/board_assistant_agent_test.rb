require "test_helper"

class BoardAssistantAgentTest < ActiveSupport::TestCase
  setup do
    sync_agents
    @board = Board.create!(name: "Launch")
    @todo = @board.list_named("To do")
  end

  def run_turn(*events)
    anthropic.respond_with(*events)
    session = BoardAssistantAgent.start("Help with the board", subject: @board, run: false)
    session.run_now
    session
  end

  def tool_results
    anthropic.tool_results.map { |result| [result[:is_error], JSON.parse(result[:content].first[:text])] }
  rescue JSON::ParserError
    anthropic.tool_results.map { |result| [result[:is_error], result[:content].first[:text]] }
  end

  test "the definition and the handlers agree" do
    assert_empty ManagedAgents::Sync.new(io: StringIO.new).problems
  end

  test "list_cards returns the board as the agent should see it" do
    card = @todo.cards.create!(title: "Write announcement", description: "Blog post")

    run_turn custom_tool_use("list_cards"), agent_message("Here is the board."), idle

    error, lists = tool_results.sole
    refute error
    assert_equal ["To do", "Doing", "Done"], lists.map { |list| list["list"] }
    assert_equal [{"id" => card.id, "title" => "Write announcement", "description" => "Blog post"}], lists.first["cards"]
  end

  test "create_card adds a card to the named list" do
    run_turn custom_tool_use("create_card", list: "doing", title: "Pricing page", description: "Copy and layout"), idle

    card = @board.list_named("Doing").cards.sole
    assert_equal ["Pricing page", "Copy and layout"], [card.title, card.description]
    assert_equal [false, {"id" => card.id, "list" => "Doing", "title" => "Pricing page"}], tool_results.sole
  end

  test "move_card moves a card between lists" do
    card = @todo.cards.create!(title: "Record demo")

    run_turn custom_tool_use("move_card", card_id: card.id, list: "Done"), idle

    assert_equal "Done", card.reload.list.name
  end

  test "update_card changes only what was given" do
    card = @todo.cards.create!(title: "Recrod demo", description: "Two minutes")

    run_turn custom_tool_use("update_card", card_id: card.id, title: "Record demo"), idle

    assert_equal ["Record demo", "Two minutes"], card.reload.values_at(:title, :description)
  end

  test "an unknown list is explained to the agent, with the lists that exist" do
    run_turn custom_tool_use("create_card", list: "Backlog", title: "Someday"), agent_message("Which list?"), idle

    error, message = tool_results.sole
    assert error
    assert_equal 'There is no list called "Backlog". Lists: To do, Doing, Done', message
    assert_equal 0, @board.cards.count
  end

  test "the agent cannot touch cards on another board" do
    other = Board.create!(name: "Other").list_named("To do").cards.create!(title: "Not yours")

    run_turn custom_tool_use("move_card", card_id: other.id, list: "Done"), idle

    assert tool_results.sole.first
    assert_equal "To do", other.reload.list.name
  end

  test "input that does not match the schema is rejected before the handler runs" do
    run_turn custom_tool_use("create_card", list: "To do"), idle

    error, message = tool_results.sole
    assert error
    assert_match "input.title is required", message
  end
end

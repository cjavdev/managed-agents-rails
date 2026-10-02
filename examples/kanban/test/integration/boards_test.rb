require "test_helper"

class BoardsTest < ActionDispatch::IntegrationTest
  setup do
    sync_agents
    @board = Board.create!(name: "Launch")
    @card = @board.list_named("To do").cards.create!(title: "Write announcement")
  end

  test "the board shows its lists, cards and the assistant" do
    get board_path(@board)

    assert_response :success
    assert_select ".list h2", text: /To do/
    assert_select ".card h3", text: "Write announcement"
    assert_select ".assistant form[action='#{board_messages_path(@board)}'] textarea[name=message]"
  end

  test "adding and moving a card by hand" do
    post list_cards_path(@board.list_named("Doing")), params: {card: {title: "Pricing page"}}
    assert_redirected_to @board

    patch card_path(@card), params: {list_id: @board.list_named("Done").id}
    assert_equal "Done", @card.reload.list.name
  end

  test "the first message starts a session about this board" do
    assert_enqueued_with(job: ManagedAgents::SessionJob) do
      post board_messages_path(@board), params: {message: "Add a card for the demo video"}
    end

    assert_redirected_to @board
    session = @board.assistant_session
    assert_equal "board_assistant", session.agent_name
    assert_equal @board, session.subject
    assert_equal "Add a card for the demo video", session.events.sole.text
  end

  test "later messages continue the same session" do
    post board_messages_path(@board), params: {message: "Add a card for the demo video"}

    assert_no_difference -> { ManagedAgents::Session.count } do
      post board_messages_path(@board), params: {message: "And one for the blog post"}, as: :turbo_stream
    end

    assert_response :no_content
    assert_equal 2, @board.assistant_session.events.where(event_type: "user.message").count
  end

  test "a whole turn: the agent creates a card and the board shows it" do
    post board_messages_path(@board), params: {message: "Add a card for the demo video"}
    anthropic.respond_with custom_tool_use("create_card", list: "To do", title: "Record the demo video"),
      agent_message("Added “Record the demo video” to To do."), idle

    perform_enqueued_jobs

    get board_path(@board)
    assert_select ".card h3", text: "Record the demo video"
    assert_select ".ma-bubble--agent", text: /Added/
    assert_select ".ma-tool code", text: "create_card"
  end

  test "before the agent is synced, sending a message explains what to run" do
    ManagedAgents::Resource.delete_all

    post board_messages_path(@board), params: {message: "Hello"}
    follow_redirect!

    assert_select ".ma-note--error", text: /managed_agents:sync/
  end
end

# Kanban example

A small Trello-style board with an assistant that reads the board and creates, moves and updates
cards. Everything the agent does goes through four custom tools handled by the Rails app, so it
needs no network access and no credentials of its own.

```sh
bundle install
bin/rails db:prepare          # creates the database and a sample board
bin/rails managed_agents:sync # creates the agent and environment in your workspace
bin/rails server
```

Open a board and ask the assistant for something: "Add cards for launching the pricing page", or
"Move everything about billing to Doing". The board redraws as the agent works.

Where to look:

- `app/agents/board_assistant/agent.md`: the prompt and the tool schemas.
- `app/agents/board_assistant_agent.rb`: the tool handlers. `subject` is the board.
- `app/controllers/boards/messages_controller.rb`: starts or continues the board's session.
- `app/views/boards/_assistant.html.erb`: the chat panel, built from the engine's event partials.
- `test/agents/board_assistant_agent_test.rb`: tool tests with the fake client.

`/agent_sessions` lists every session with its full transcript (from `managed_agents:chat`).

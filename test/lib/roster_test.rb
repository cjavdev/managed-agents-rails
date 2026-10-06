require "test_helper"

class RosterTest < ActiveSupport::TestCase
  setup do
    with_agents(agent_files("desk", agent: <<~MD).merge(
      ---
      name: Desk lead
      model: claude-opus-5-5
      multiagent:
        type: coordinator
        agents:
          - ./agent-writer.md
      tools:
        - type: custom
          name: submit
          description: Submit the result.
          input_schema: {type: object, properties: {text: {type: string}}, required: [text]}
      ---

      You coordinate.
    MD
      "desk/agent-writer.md" => <<~MD
        ---
        name: Writer
        model: claude-sonnet-5-5
        tools:
          - type: custom
            name: lookup
            description: Look something up.
            input_schema: {type: object, properties: {q: {type: string}}}
        ---

        You write.
      MD
    ))
  end

  test "syncs the roster agent first and pins it in the coordinator" do
    changes, = sync

    assert_equal [["environment", ""], ["agent", "writer"], ["agent", ""]], changes.map { |change| [change.kind, change.key] }
    writer = resource("desk", "agent", "writer")
    assert_match %r{/desk/agent-writer\.md\z}, writer.path

    created = anthropic.calls_to(:"agent.create")
    assert_equal "Writer", created.first[:name]
    assert_equal "You write.", created.first[:system_]
    assert_equal [{type: "agent", id: writer.remote_id, version: 1}], created.last.dig(:multiagent, :agents)
  end

  test "a roster change updates the roster agent and re-pins the coordinator" do
    sync
    root = Rails.root.join(ManagedAgents.config.agents_path)
    File.write(root.join("desk/agent-writer.md"), File.read(root.join("desk/agent-writer.md")).sub("You write.", "You write well."))

    changes, = sync

    assert_equal %i[unchanged update update], changes.map(&:action)
    assert_equal 2, anthropic.calls_to(:"agent.update").last.dig(:multiagent, :agents, 0, :version)
  end

  test "status lists roster agents" do
    sync

    rows = ManagedAgents::Sync.new(io: StringIO.new).status
    assert_includes rows.map { |row| [row[1], row.last] }, ["agent writer", "synced"]
  end

  test "custom tools declared by roster agents count as the agent's" do
    assert_equal %w[submit lookup], ManagedAgents.definition("desk").custom_tools.map { |tool| tool["name"] }
  end

  test "a roster agent without a model is a problem" do
    root = Rails.root.join(ManagedAgents.config.agents_path)
    File.write(root.join("desk/agent-writer.md"), "---\nname: Writer\n---\n\nYou write.\n")

    assert_includes ManagedAgents.definition("desk").problems, "desk: roster agent writer needs a model"
  end
end

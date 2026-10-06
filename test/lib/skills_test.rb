require "test_helper"

class SkillsTest < ActiveSupport::TestCase
  setup do
    @root = with_agents(agent_files("desk", agent: <<~MD).merge(
      ---
      name: Desk
      model: claude-opus-5-5
      skills:
        - ./skills/voice
        - {type: anthropic, skill_id: xlsx}
      ---

      You write.
    MD
      "desk/skills/voice/SKILL.md" => "---\nname: voice\ndescription: How CJ sounds.\n---\n\nRead guide.md.\n",
      "desk/skills/voice/guide.md" => "Short sentences.\n"
    ))
  end

  test "uploads the skill under its own directory and pins its version in the agent" do
    changes, = sync

    assert_equal [["skill", "voice"], ["environment", ""], ["agent", ""]], changes.map { |change| [change.kind, change.key] }
    upload = anthropic.calls_to(:"skill.create").sole
    assert_equal "voice", upload[:display_name]
    assert_equal %w[voice/SKILL.md voice/guide.md], upload[:files]

    skill = resource("desk", "skill", "voice")
    skills = anthropic.calls_to(:"agent.create").sole[:skills]
    assert_equal({type: "custom", skill_id: skill.remote_id, version: skill.remote_version}, skills.first)
    assert_equal({type: "anthropic", skill_id: "xlsx"}, skills.last)
  end

  test "editing a skill file uploads a new version and re-pins the agent" do
    sync
    first = resource("desk", "skill", "voice").remote_version
    File.write(@root.join("desk/skills/voice/guide.md"), "Shorter sentences.\n")

    changes, = sync

    assert_equal %i[update unchanged update], changes.map(&:action)
    version = resource("desk", "skill", "voice").remote_version
    refute_equal first, version
    assert_equal version, anthropic.calls_to(:"agent.update").sole.dig(:skills, 0, :version)
  end

  test "a second sync changes nothing and status reports the skill as synced" do
    sync
    changes, = sync

    assert_equal %i[unchanged] * 3, changes.map(&:action)
    rows = ManagedAgents::Sync.new(io: StringIO.new).status
    assert_includes rows.map { |row| [row[1], row.last] }, ["skill voice", "synced"]
  end

  test "pruning a deleted skill forgets it without deleting it remotely" do
    sync
    FileUtils.rm_rf(@root.join("desk/skills"))
    File.write(@root.join("desk/agent.md"), "---\nname: Desk\nmodel: claude-opus-5-5\n---\n\nYou write.\n")

    sync(prune: true)

    assert_nil resource("desk", "skill", "voice")
    assert_empty anthropic.calls_to(:"skill.delete")
  end
end

require "test_helper"

class SharedEnvironmentTest < ActiveSupport::TestCase
  def shared_files
    agent_files("analyst").merge(
      "reviewer/agent.md" => "---\nname: Reviewer\nmodel: claude-opus-5-5\nenvironment: ../analyst/environment.yaml\n---\n\nYou review.\n"
    )
  end

  test "an agent can name another agent's environment instead of having its own" do
    with_agents(shared_files)
    definition = ManagedAgents.definition("reviewer")

    assert definition.shared_environment?
    assert_equal "analyst", definition.environment_owner
    assert_empty definition.problems
    refute definition.agent_body.key?("environment"), "environment is not part of the agent the API creates"
  end

  test "sync creates the environment once and both agents start sessions in it" do
    with_agents(shared_files)
    changes, = sync

    assert_equal 1, changes.count { |change| change.kind == "environment" }
    assert_nil resource("reviewer", "environment")
    refute anthropic.calls_to(:"agent.create").any? { |params| params.key?(:environment) }

    ManagedAgents.agent("reviewer").start("Review", run: false)
    assert_equal resource("analyst", "environment").remote_id, anthropic.calls_to(:"sesn.create").sole[:environment_id]
    assert ManagedAgents.agent("reviewer").synced?
  end

  test "a second sync changes nothing and nothing is orphaned" do
    with_agents(shared_files)
    sync
    changes, = sync

    assert_equal [:unchanged], changes.map(&:action).uniq
    assert_equal %w[synced], ManagedAgents::Sync.new(io: StringIO.new).status.map(&:last).uniq
  end

  test "a reference that is not another agent's environment is a problem" do
    with_agents(agent_files("analyst").merge(
      "own/agent.md" => "---\nname: Own\nmodel: claude-opus-5-5\nenvironment: ./environment.yaml\n---\n\nHi\n",
      "own/environment.yaml" => "name: own-env\n",
      "missing/agent.md" => "---\nname: Missing\nmodel: claude-opus-5-5\nenvironment: ../nowhere/environment.yaml\n---\n\nHi\n",
      "literal/agent.md" => "---\nname: Literal\nmodel: claude-opus-5-5\nenvironment: env_123\n---\n\nHi\n"
    ))

    assert_includes ManagedAgents.definition("own").problems.join, "keep one"
    assert_includes ManagedAgents.definition("missing").problems.join, "does not point at another agent's environment.yaml"
    assert_includes ManagedAgents.definition("literal").problems.join, "must be a relative path"
  end

  test "ant apply gets the shared environment once and an agent file without the environment key" do
    log = Rails.root.join("tmp/fake_ant.log")
    FileUtils.rm_f(log)
    ENV["FAKE_ANT_LOG"] = log.to_s
    ManagedAgents.config.ant_bin = File.expand_path("../support/fake_ant", __dir__)
    with_agents(shared_files)

    ManagedAgents::Sync.new(backend: :ant, io: StringIO.new).apply

    files = JSON.parse(log.readlines.sole)["argv"].grep(/\.(md|yaml)\z/)
    assert_equal 1, files.count { |file| file.end_with?("environment.yaml") }
    reviewer = files.find { |file| file.include?("reviewer/agent.md") }
    refute_includes Rails.root.join("tmp/managed_agents/build", reviewer).read, "environment:"
    assert_equal resource("analyst", "environment").remote_id, ManagedAgents.agent("reviewer").environment_id
  ensure
    ENV.delete("FAKE_ANT_LOG")
    FileUtils.rm_f(log)
  end
end

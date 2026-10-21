require "test_helper"

class MemoryStoresTest < ActiveSupport::TestCase
  def files
    agent_files("researcher").merge(
      "researcher/memory.yaml" => "description: What the researcher learned about each ticker\n",
      "researcher/memory-house-style.yaml" => "name: House style\naccess: read_only\ninstructions: Follow it; never write to it.\n"
    )
  end

  test "memory.yaml and memory-<key>.yaml are memory stores, synced with the agent" do
    with_agents(files)
    changes, = sync

    assert_equal [%w[memory_store default], %w[memory_store house-style]],
      changes.select { |change| change.kind == "memory_store" }.map { |change| [change.kind, change.key] }
    created = anthropic.calls_to(:"memstore.create")
    assert_equal ["researcher memory", "House style"], created.map { |params| params[:name] }
    assert_equal "What the researcher learned about each ticker", created.first[:description]

    changes, = sync
    assert_equal [:unchanged], changes.map(&:action).uniq
  end

  test "sessions get the agent's memory stores, with their access and instructions" do
    with_agents(files)
    sync

    ManagedAgents.agent("researcher").start("Go", run: false)

    resources = anthropic.calls_to(:"sesn.create").sole[:resources]
    assert_equal [
      {type: "memory_store", memory_store_id: resource("researcher", "memory_store", "default").remote_id},
      {type: "memory_store", memory_store_id: resource("researcher", "memory_store", "house-style").remote_id,
       access: "read_only", instructions: "Follow it; never write to it."}
    ], resources
  end

  test "memory: false leaves them out, and other resources are kept" do
    with_agents(files)
    sync
    repo = {type: "github_repository", url: "https://github.com/acme/app"}

    ManagedAgents.agent("researcher").start("Go", run: false, memory: false, resources: [repo])

    assert_equal [repo], anthropic.calls_to(:"sesn.create").sole[:resources]
  end

  test "a memory store deleted outside the files is made again, empty" do
    with_agents(files)
    sync
    gone = resource("researcher", "memory_store", "default").remote_id
    anthropic.beta.memory_stores.records.delete(gone)

    changes, = sync

    assert_equal [["memory_store", "default", :create]],
      changes.reject { |change| change.action == :unchanged }.map { |change| [change.kind, change.key, change.action] }
    refute_equal gone, resource("researcher", "memory_store", "default").remote_id
  end

  test "a skill deleted outside the files is uploaded again" do
    with_agents(agent_files("writer").merge("writer/skills/tone/SKILL.md" => "---\nname: tone\ndescription: Our tone\n---\n\nBe brief.\n"))
    sync
    gone = resource("writer", "skill", "tone").remote_id
    anthropic.beta.skills.records.delete(gone)

    sync

    refute_equal gone, resource("writer", "skill", "tone").remote_id
  end

  test "an access other than read_write or read_only is a problem" do
    with_agents(agent_files("researcher").merge("researcher/memory.yaml" => "access: everything\n"))

    assert_includes ManagedAgents.definition("researcher").problems, "researcher: memory default access must be read_write or read_only"
  end
end

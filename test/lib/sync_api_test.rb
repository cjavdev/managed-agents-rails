require "test_helper"

class SyncApiTest < ActiveSupport::TestCase
  test "creates the environment, vault, credential, agent and deployment and records their IDs" do
    changes, output = sync

    assert_equal %i[create] * 5, changes.map(&:action)
    assert_equal %w[vault credential environment agent deployment], changes.map(&:kind)
    assert_match "Synced (api backend): 5 create", output

    agent = resource("support_triage", "agent")
    assert_match(/\Aagent_/, agent.remote_id)
    assert_equal "1", agent.remote_version
    assert_equal "api", agent.backend
    assert_equal "app/agents/support_triage/agent.md", agent.path
    assert_match(/\Aenv_/, resource("support_triage", "environment").remote_id)
    assert_match(/\Adepl_/, resource("support_triage", "deployment", "daily").remote_id)
  end

  test "sends the system prompt and tools from agent.md" do
    sync

    params = anthropic.calls_to(:"agent.create").sole
    assert_equal "Support triage", params[:name]
    assert_match "You triage support tickets", params[:system_]
    assert_equal "set_priority", params[:tools].last[:name]
    refute params.key?(:system)
  end

  test "a deployment is sent with IDs in place of paths and pinned to the agent version" do
    sync

    params = anthropic.calls_to(:"depl.create").sole
    assert_equal({type: "agent", id: resource("support_triage", "agent").remote_id, version: 1}, params[:agent])
    assert_equal resource("support_triage", "environment").remote_id, params[:environment_id]
    assert_equal [resource("support_triage", "vault").remote_id], params[:vault_ids]
    assert_equal "user.message", params[:initial_events].first[:type]
  end

  test "a Markdown deployment uses its body as the kickoff message" do
    with_agents(agent_files.merge(
      "helper/deployment-nightly.md" => <<~MD
        ---
        name: Nightly
        agent: ./agent.md
        environment_id: ./environment.yaml
        schedule: {type: cron, expression: "0 2 * * *", timezone: UTC}
        ---

        Tidy up.
      MD
    ))
    sync

    events = anthropic.calls_to(:"depl.create").sole[:initial_events]
    assert_equal [{type: "user.message", content: [{type: "text", text: "Tidy up."}]}], events
  end

  test "a second sync changes nothing" do
    sync
    anthropic.calls.clear

    changes, output = sync

    assert_equal [:unchanged], changes.map(&:action).uniq
    assert_empty anthropic.calls
    assert_match "5 unchanged", output
  end

  test "editing agent.md updates the agent and re-pins its deployments" do
    root = with_agents(agent_files.merge(
      "helper/deployment-daily.yaml" => "name: Daily\nagent: ./agent.md\nenvironment_id: ./environment.yaml\n" \
        "initial_events: [{type: user.message, content: [{type: text, text: Go}]}]\n"
    ))
    sync
    File.write(root.join("helper/agent.md"), "---\nname: Helper\nmodel: claude-opus-5-5\n---\n\nYou help a lot.\n")
    ManagedAgents::Definition.find("helper") # definitions are read fresh on every sync

    changes, = sync

    assert_equal({"environment" => :unchanged, "agent" => :update, "deployment" => :update},
      changes.to_h { |change| [change.kind, change.action] })
    assert_equal "2", resource("helper", "agent").remote_version
    assert_equal 2, anthropic.calls_to(:"depl.update").sole.dig(:agent, :version)
  end

  test "an agent update passes the current version and clears fields removed from the file" do
    root = with_agents(agent_files("helper", agent: "---\nname: Helper\nmodel: claude-opus-5-5\ndescription: Helps\n---\n\nYou help.\n"))
    sync
    File.write(root.join("helper/agent.md"), "---\nname: Helper\nmodel: claude-opus-5-5\n---\n")

    sync

    params = anthropic.calls_to(:"agent.update").sole
    assert_equal 1, params[:version]
    assert_nil params[:description]
    assert_nil params[:system_]
    assert_equal [], params[:tools]
  end

  test "refuses to overwrite an agent that was changed outside the files" do
    root = with_agents(agent_files)
    sync
    anthropic.beta.agents.update(resource("helper", "agent").remote_id, name: "Edited in the Console")
    File.write(root.join("helper/agent.md"), "---\nname: Helper\nmodel: claude-opus-5-5\n---\n\nNew prompt.\n")

    error = assert_raises(ManagedAgents::Drift) { sync }
    assert_match "--force", error.message

    sync(force: true)
    assert_equal "3", resource("helper", "agent").remote_version
  end

  test "a dry run reports the plan without calling the API or writing rows" do
    changes, output = sync(dry_run: true)

    assert_equal [:create], changes.map(&:action).uniq
    assert_match "Plan (api backend): 5 create", output
    assert_empty anthropic.calls
    assert_equal 0, ManagedAgents::Resource.count
  end

  test "an environment name that already exists needs --adopt" do
    with_agents(agent_files)
    existing = anthropic.beta.environments.create(name: "helper-env")

    error = assert_raises(ManagedAgents::SyncError) { sync }
    assert_match "--adopt", error.message

    sync(adopt: true)
    assert_equal existing.id, resource("helper", "environment").remote_id
  end

  test "resources whose files are gone are reported, and archived with --prune" do
    root = with_agents(agent_files.merge(
      "helper/deployment-daily.yaml" => "name: Daily\nagent: ./agent.md\nenvironment_id: ./environment.yaml\n" \
        "initial_events: [{type: user.message, content: [{type: text, text: Go}]}]\n"
    ))
    sync
    deployment_id = resource("helper", "deployment", "daily").remote_id
    FileUtils.rm(root.join("helper/deployment-daily.yaml"))

    changes, output = sync
    assert_equal :orphaned, changes.last.action
    assert_match "pass --prune to archive", output
    assert resource("helper", "deployment", "daily")

    sync(prune: true)
    assert_nil resource("helper", "deployment", "daily")
    assert anthropic.beta.deployments.retrieve(deployment_id).archived_at
  end

  test "a second sync running at the same time is refused where the database has advisory locks" do
    connection = ManagedAgents::Resource.connection
    stub_method(connection, :supports_advisory_locks?, -> { true }) do
      stub_method(connection, :get_advisory_lock, ->(_id) { false }) do
        error = assert_raises(ManagedAgents::SyncError) { sync }
        assert_match "already running", error.message
        assert_empty anthropic.calls
      end

      released = []
      stub_method(connection, :get_advisory_lock, ->(_id) { true }) do
        stub_method(connection, :release_advisory_lock, ->(id) { released << id }) { sync }
      end
      assert_equal 1, released.size
      assert resource("support_triage", "agent")
    end
  end

  test "only syncs the named agent when asked" do
    with_agents(agent_files("one").merge(agent_files("two")))

    sync(only: "two")

    assert_nil resource("one", "agent")
    assert resource("two", "agent")
  end

  test "invalid definitions stop the sync before anything is sent" do
    with_agents("broken/agent.md" => "---\nname: Broken\n---\n")

    error = assert_raises(ManagedAgents::DefinitionError) { sync }
    assert_match "environment.yaml is missing", error.message
    assert_empty anthropic.calls
  end

  test "refuses to sync a database that belongs to another workspace" do
    ManagedAgents.config.workspace_id = "wrkspc_dev"
    sync
    assert_equal "wrkspc_dev", resource("support_triage", "agent").workspace_id

    ManagedAgents.config.workspace_id = "wrkspc_prod"
    error = assert_raises(ManagedAgents::WorkspaceMismatch) { sync }
    assert_match "wrkspc_dev", error.message
  end

  test "status shows what is synced, pending and missing" do
    sync_instance = ManagedAgents::Sync.new(backend: :api, io: StringIO.new)
    assert_equal ["not synced"], sync_instance.status.map(&:last).uniq

    sync
    states = ManagedAgents::Sync.new(backend: :api, io: StringIO.new).status
    assert_equal ["synced"], states.map(&:last).uniq
    assert_includes states.map { |row| row[1] }, "deployment daily"

    ENV["HELPDESK_MCP_TOKEN"] = "rotated"
    states = ManagedAgents::Sync.new(backend: :api, io: StringIO.new).status
    assert_equal "pending", states.find { |row| row[1].start_with?("credential") }.last
  end

  test "check reports tools without handlers and handlers without tools" do
    with_agents(agent_files("support_triage", agent: <<~MD))
      ---
      name: Support triage
      model: claude-opus-5-5
      tools:
        - {type: custom, name: escalate, description: Escalate, input_schema: {type: object}}
      ---
    MD

    problems = ManagedAgents::Sync.new(io: StringIO.new).problems
    assert_includes problems, "support_triage: custom tool escalate has no handler"
    assert_includes problems, "support_triage: handler set_priority is not declared in agent.md"
  end
end

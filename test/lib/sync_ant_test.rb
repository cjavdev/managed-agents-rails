require "test_helper"

class SyncAntTest < ActiveSupport::TestCase
  setup do
    @log = Rails.root.join("tmp/fake_ant.log")
    FileUtils.rm_f(@log)
    ENV["FAKE_ANT_LOG"] = @log.to_s
    ManagedAgents.config.ant_bin = File.expand_path("../support/fake_ant", __dir__)
  end

  teardown do
    %w[FAKE_ANT_LOG FAKE_ANT_FAIL_ON FAKE_ANT_VERSION FAKE_ANT_WORKSPACE].each { |name| ENV.delete(name) }
    FileUtils.rm_f(@log)
  end

  def ant_sync(**)
    output = StringIO.new
    changes = ManagedAgents::Sync.new(io: output, **).apply
    [changes, output.string]
  end

  def invocations
    @log.exist? ? @log.readlines.map { |line| JSON.parse(line) } : []
  end

  test "auto picks ant when the CLI is installed and nothing was synced through the API" do
    assert_equal "ant", ManagedAgents::Sync.new.backend_name
  end

  test "auto falls back to the API when ant is missing or too old" do
    ManagedAgents.config.ant_bin = "definitely-not-installed"
    assert_equal "api", ManagedAgents::Sync.new.backend_name

    ManagedAgents.config.ant_bin = File.expand_path("../support/fake_ant", __dir__)
    ENV["FAKE_ANT_VERSION"] = "1.29.0"
    assert_equal "api", ManagedAgents::Sync.new.backend_name
  end

  test "auto stays on the API once resources were created through it" do
    sync
    assert_equal "api", ManagedAgents::Sync.new.backend_name
  end

  test "asking for ant after an API sync is refused, because ant would create duplicates" do
    sync
    error = assert_raises(ManagedAgents::SyncError) { ant_sync(backend: :ant) }
    assert_match "duplicates", error.message
  end

  test "asking for ant when it is not installed is an error" do
    ManagedAgents.config.ant_bin = "definitely-not-installed"
    assert_raises(ManagedAgents::SyncError) { ant_sync(backend: :ant) }
  end

  test "runs ant apply in the build directory with a lockfile and the rendered files" do
    ant_sync

    call = invocations.sole
    assert_equal Rails.root.join("tmp/managed_agents/build").to_s, File.realpath(call["cwd"]).sub(File.realpath(Rails.root), Rails.root.to_s)
    assert_equal ["apply", "--yes", "--lock-file", "claude-lock.json",
      "app/agents/support_triage/environment.yaml",
      "app/agents/support_triage/agent.md",
      "app/agents/support_triage/deployment-daily.yaml"], call["argv"]
  end

  test "the files handed to ant are rendered, with vault paths replaced by IDs" do
    ant_sync
    build = Rails.root.join("tmp/managed_agents/build/app/agents/support_triage")

    assert_match "name: dummy-support-triage-test", build.join("environment.yaml").read
    assert_match "You triage support tickets for Dummy.", build.join("agent.md").read

    deployment = YAML.safe_load(build.join("deployment-daily.yaml").read)
    assert_equal [resource("support_triage", "vault").remote_id], deployment["vault_ids"]
    assert_equal "./agent.md", deployment["agent"], "ant resolves agent and environment paths itself"
  end

  test "records the IDs from the lockfile in the database" do
    changes, output = ant_sync

    agent = resource("support_triage", "agent")
    assert_equal "agent_ant2", agent.remote_id
    assert_equal "1", agent.remote_version
    assert_equal "ant", agent.backend
    assert_equal "wrkspc_fake", agent.workspace_id
    assert_equal "app/agents/support_triage/agent.md", agent.path
    assert_equal "agent_ant2", agent.lock_data.dig("entry", "id")
    assert_equal "deplo_ant3", resource("support_triage", "deployment", "daily").remote_id

    assert_equal %i[create create create], changes.last(3).map(&:action)
    assert_match "+ ./app/agents/support_triage/agent.md  create", output
    assert_match "Synced (ant backend)", output
  end

  test "vaults and credentials still go through the SDK" do
    ant_sync

    assert_equal "api", resource("support_triage", "vault").backend
    assert_equal 1, anthropic.calls_to(:"vcrd.create").size
    assert_empty anthropic.calls_to(:"agent.create")
  end

  test "the next run rebuilds the lockfile from the database, so nothing is created twice" do
    ant_sync
    FileUtils.rm_rf(Rails.root.join("tmp/managed_agents"))

    changes, output = ant_sync

    assert_equal %i[unchanged unchanged unchanged], changes.last(3).map(&:action)
    assert_match "= ./app/agents/support_triage/agent.md  unchanged", output
    assert_equal "agent_ant2", resource("support_triage", "agent").remote_id
  end

  test "an edited file is an update and bumps the recorded version" do
    root = with_agents(agent_files)
    ant_sync
    File.write(root.join("helper/agent.md"), "---\nname: Helper\nmodel: claude-opus-5-5\n---\n\nChanged.\n")

    changes, = ant_sync

    assert_equal({"environment" => :unchanged, "agent" => :update}, changes.to_h { |change| [change.kind, change.action] })
    assert_equal "2", resource("helper", "agent").remote_version
  end

  test "what ant created before failing is still recorded" do
    ENV["FAKE_ANT_FAIL_ON"] = "deployment-daily"

    error = assert_raises(ManagedAgents::SyncError) { ant_sync }
    assert_match "ant apply", error.message
    assert resource("support_triage", "agent")
    assert_nil resource("support_triage", "deployment", "daily")
  end

  test "a dry run passes --dry-run and records nothing" do
    _, output = ant_sync(dry_run: true)

    assert_includes invocations.sole["argv"], "--dry-run"
    refute_includes invocations.sole["argv"], "--yes"
    assert_nil resource("support_triage", "agent")
    assert_match "Plan (ant backend)", output
  end

  test "--force is passed through" do
    ant_sync(force: true)
    assert_includes invocations.sole["argv"], "--force"
  end

  test "status compares the rendered file with what was applied" do
    root = with_agents(agent_files)
    ant_sync
    assert_equal %w[synced synced], ManagedAgents::Sync.new.status.map(&:last)

    File.write(root.join("helper/agent.md"), "---\nname: Helper\nmodel: claude-opus-5-5\n---\n\nChanged.\n")
    assert_equal %w[synced pending], ManagedAgents::Sync.new.status.map(&:last)
  end

  test "moving from ant to the API updates the same resources by ID" do
    with_agents(agent_files)
    ant_sync
    anthropic.beta.agents.store(ManagedAgents::Testing::Record.new(id: "agent_ant2", version: 1, name: "Helper"))
    anthropic.beta.environments.store(ManagedAgents::Testing::Record.new(id: "envir_ant1", name: "helper-env"))

    sync

    assert_equal "agent_ant2", resource("helper", "agent").remote_id
    assert_equal "api", resource("helper", "agent").backend
    assert_empty anthropic.calls_to(:"agent.create")
  end

  test "an API key that only lives in configuration is handed to the CLI" do
    ManagedAgents.config.api_key = "sk-ant-from-credentials"
    original = ENV.delete("ANTHROPIC_API_KEY")

    ant_sync

    assert_equal "sk-ant-from-credentials", invocations.sole["api_key"]
  ensure
    ENV["ANTHROPIC_API_KEY"] = original if original
  end
end

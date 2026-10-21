require "test_helper"

# A workspace can lose what sync made: an agent deleted in the Console, an
# environment archived, a workspace reset. The next sync builds it again.
class SyncRebuildTest < ActiveSupport::TestCase
  def wipe!
    beta = anthropic.beta
    [beta.agents, beta.environments, beta.vaults, beta.vaults.credentials, beta.deployments].each { |collection| collection.records.clear }
  end

  def ids = ManagedAgents::Resource.order(:kind, :key).pluck(:kind, :key, :remote_id)

  test "a wiped workspace is built again from the files" do
    sync
    before = ids

    wipe!
    changes, output = sync

    assert_equal %w[vault credential environment agent deployment], changes.select { |change| change.action == :create }.map(&:kind)
    assert_equal before.map { |kind, key, _| [kind, key] }, ids.map { |kind, key, _| [kind, key] }
    assert_empty before & ids, "every resource has a new remote ID"
    assert_match(/missing\s+support_triage\s+agent/, output)
    assert_equal resource("support_triage", "environment").remote_id, anthropic.calls_to(:"depl.create").last[:environment_id]

    changes, = sync
    assert_equal [:unchanged], changes.map(&:action).uniq, "and then it is left alone"
  end

  test "an environment archived in the Console is made again, and what points at it follows" do
    sync
    anthropic.beta.environments.archive(resource("support_triage", "environment").remote_id)

    changes, = sync

    assert_equal [["environment", :create], ["deployment", :update]], changes.reject { |change| change.action == :unchanged }.map { |change| [change.kind, change.action] }
  end

  test "a vault that is gone takes its credentials, and a signed-in one is reported as not connected" do
    with_agents(agent_files("fixer").merge("fixer/vault.yaml" => <<~YAML))
      display_name: fixer
      credentials:
        - display_name: Sentry
          connect: oauth
          auth: {type: mcp_oauth, mcp_server_url: "https://mcp.sentry.example/mcp"}
    YAML
    sync
    ManagedAgents::Resource.record!(agent_name: "fixer", kind: "credential", key: "https://mcp.sentry.example/mcp", remote_id: "vcrd_signed_in", backend: "api")
    anthropic.beta.vaults.records.clear

    changes, = sync

    assert_equal :create, changes.find { |change| change.kind == "vault" }.action
    assert_equal :not_connected, changes.find { |change| change.kind == "credential" }.action
    assert_nil resource("fixer", "credential", "https://mcp.sentry.example/mcp")
  end

  test "a dry run says what is missing and changes nothing" do
    sync
    wipe!

    _, output = sync(dry_run: true)

    assert_match(/missing\s+support_triage\s+agent .* would be made again/, output)
    assert resource("support_triage", "agent"), "the rows are kept"
  end

  test "verify: false trusts the records" do
    sync
    wipe!

    changes, = sync(verify: false)

    assert_equal [:unchanged], changes.map(&:action).uniq
  end
end

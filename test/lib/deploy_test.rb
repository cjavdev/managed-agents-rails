require "test_helper"

class DeployTest < ActiveSupport::TestCase
  def files
    agent_files("fixer").merge("fixer/vault.yaml" => <<~YAML)
      display_name: fixer
      credentials:
        - display_name: Logs
          optional: true
          auth: {type: static_bearer, mcp_server_url: "https://mcp.logs.example/mcp", token: {credential: logs_example.token}}
        - display_name: Sentry
          connect: oauth
          auth: {type: mcp_oauth, mcp_server_url: "https://mcp.sentry.example/mcp"}
    YAML
  end

  def deploy(**)
    io = StringIO.new
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(ManagedAgents::Deploy::EVENT) { |event| events << event.payload[:report] }
    report = ManagedAgents::Deploy.run(io: io, backend: :api, **)
    [report, io.string, events]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "syncs, and reports the missing secret and the sign-in that need a person" do
    with_agents(files)

    report, output, events = deploy

    assert report.ok?
    assert report.attention?
    assert resource("fixer", "agent"), "the agent was created"
    assert_equal ["https://mcp.logs.example/mcp"], report.missing_secrets.map(&:key)
    assert_equal ["bin/rails managed_agents:connect fixer https://mcp.sentry.example/mcp"], report.sign_in_commands
    assert_match "logs_example.token", report.summary
    assert_match "Needs attention:", output
    assert_equal [report], events
  end

  test "nothing to say when everything is in place" do
    with_agents(agent_files("helper"))

    report, output, events = deploy

    refute report.attention?
    assert_empty report.summary
    refute_match "Needs attention", output
    assert_equal [report], events, "the event fires either way"
  end

  test "a sync that fails is reported, not raised, unless asked" do
    with_agents(agent_files("helper"))
    anthropic.beta.agents.define_singleton_method(:create) { |**| raise ManagedAgents::SyncError, "the API is down" }

    report, output, = deploy

    refute report.ok?
    assert_match "Sync failed (SyncError): the API is down", output
    assert_raises(ManagedAgents::SyncError) { deploy(raise_errors: true) }
  end

  test "rebuilds what was deleted, and takes over a same-named leftover" do
    with_agents(agent_files("helper"))
    deploy
    anthropic.beta.environments.records.clear
    anthropic.beta.environments.create(name: "helper-env", config: {type: "cloud"})

    report, = deploy

    assert report.ok?
    assert_equal anthropic.beta.environments.records.keys.sole, resource("helper", "environment").remote_id
  end
end

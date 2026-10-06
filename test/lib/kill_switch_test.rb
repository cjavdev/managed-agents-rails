require "test_helper"

class KillSwitchTest < ActiveSupport::TestCase
  test "enabled unless switched off" do
    assert ManagedAgents.enabled?

    ManagedAgents.config.enabled = false
    assert_not ManagedAgents.enabled?

    ManagedAgents.config.enabled = "false"
    assert_not ManagedAgents.enabled?
  end

  test "a callable is checked on every call" do
    switch = false
    ManagedAgents.config.enabled = -> { switch }
    assert_not ManagedAgents.enabled?

    switch = true
    assert ManagedAgents.enabled?
  end

  test "the client refuses to be used while paused" do
    ManagedAgents.config.enabled = false

    assert_raises(ManagedAgents::Paused) { ManagedAgents.client }
  end

  test "starting a session while paused calls nothing" do
    sync
    ManagedAgents.config.enabled = false

    assert_raises(ManagedAgents::Paused) { SupportTriageAgent.start("Triage") }
    ManagedAgents.config.enabled = true
    assert_empty anthropic.calls.select { |call| call.first.to_s.start_with?("sesn") }
    assert_equal 0, ManagedAgents::Session.count
  end

  test "engine jobs do nothing while paused" do
    sync
    session = SupportTriageAgent.start("Triage", run: false)
    calls = anthropic.calls.size
    ManagedAgents.config.enabled = false

    ManagedAgents::SessionJob.perform_now(session)
    ManagedAgents::DeploymentRunsJob.perform_now

    assert_equal calls, anthropic.calls.size
  end

  test "sync status and check work while paused" do
    sync
    ManagedAgents.config.enabled = false

    assert ManagedAgents::Sync.new(io: StringIO.new).status.any?
    assert_kind_of Array, ManagedAgents::Sync.new(io: StringIO.new).problems
    assert_raises(ManagedAgents::Paused) { ManagedAgents::Sync.new(io: StringIO.new).apply }
  end
end

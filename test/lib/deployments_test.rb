require "test_helper"

class DeploymentsTest < ActiveSupport::TestCase
  setup do
    sync
    @deployment = resource("support_triage", "deployment", "daily")
  end

  def fired_run
    session = anthropic.beta.sessions.create(agent: "agent_x", environment_id: "env_x")
    anthropic.beta.deployment_runs.store(ManagedAgents::Testing::Record.new(
      id: ManagedAgents::Testing.next_id("drun"), deployment_id: @deployment.remote_id, session_id: session.id,
      agent: {type: "agent", id: "agent_x", version: 3}
    ))
  end

  test "adopting a run gives the fired session a local record and a runner" do
    run = fired_run

    session = nil
    assert_enqueued_with(job: ManagedAgents::SessionJob) { session = ManagedAgents::Deployments.adopt(run.id) }

    assert_equal run.session_id, session.remote_id
    assert_equal "support_triage", session.agent_name
    assert_equal "daily", session.deployment_key
    assert_equal 3, session.agent_version
  end

  test "adopting the same run twice does nothing the second time" do
    run = fired_run
    ManagedAgents::Deployments.adopt(run.id)

    assert_no_enqueued_jobs { ManagedAgents::Deployments.adopt(run.id) }
    assert_equal 1, ManagedAgents::Session.count
  end

  test "a failed run has no session to adopt" do
    run = anthropic.beta.deployment_runs.store(ManagedAgents::Testing::Record.new(
      id: "drun_failed", deployment_id: @deployment.remote_id, session_id: nil, error: {type: "environment_archived"}
    ))

    assert_nil ManagedAgents::Deployments.adopt(run.id)
  end

  test "runs of deployments this app does not manage are ignored" do
    run = anthropic.beta.deployment_runs.store(ManagedAgents::Testing::Record.new(
      id: "drun_other", deployment_id: "depl_someone_elses", session_id: "sesn_other"
    ))

    assert_nil ManagedAgents::Deployments.adopt(run.id)
  end

  test "polling adopts runs that have no local session yet" do
    first = fired_run
    ManagedAgents::Deployments.adopt(first.id)
    second = fired_run

    adopted = ManagedAgents::Deployments.poll

    assert_equal [second.session_id], adopted.map(&:remote_id)
    assert_equal 2, ManagedAgents::Session.count
  end

  test "an agent can fire one of its deployments now" do
    session = SupportTriageAgent.run_deployment(:daily)

    assert_equal [{id: @deployment.remote_id}], anthropic.calls_to(:"depl.run")
    assert_equal "daily", session.deployment_key
  end

  test "the polling job delegates to Deployments.poll" do
    fired_run
    assert_difference -> { ManagedAgents::Session.count }, 1 do
      ManagedAgents::DeploymentRunsJob.perform_now
    end
  end
end

require "test_helper"

class SessionJobTest < ActiveSupport::TestCase
  setup do
    sync
    @session = SupportTriageAgent.start("Triage", subject: Ticket.create!(subject: "Refund"), run: false)
  end

  test "follows the session to the end of the turn" do
    anthropic.respond_with agent_message("Done."), idle

    ManagedAgents::SessionJob.perform_now(@session)

    assert @session.reload.settled?
    assert_no_enqueued_jobs
  end

  test "enqueues a continuation when the turn outlasts one job" do
    ManagedAgents.config.max_run_time = -1
    anthropic.respond_with running

    assert_enqueued_with(job: ManagedAgents::SessionJob, args: [@session]) do
      ManagedAgents::SessionJob.perform_now(@session)
    end
  end

  test "checks back later while another job is following the session" do
    @session.acquire_lease("other", ttl: 60)

    assert_enqueued_with(job: ManagedAgents::SessionJob, args: [@session, 1]) do
      ManagedAgents::SessionJob.perform_now(@session)
    end
  end

  test "gives up checking back after a while" do
    @session.acquire_lease("other", ttl: 60)

    assert_no_enqueued_jobs do
      ManagedAgents::SessionJob.perform_now(@session, ManagedAgents::SessionJob::RETRIES_WHILE_BUSY)
    end
  end

  test "uses the configured queue" do
    ManagedAgents.config.queue = :agents
    assert_equal "agents", ManagedAgents::SessionJob.new(@session).queue_name
  end
end

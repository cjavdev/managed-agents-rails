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

  test "after the quick checks, looks once more when the other follower's lease runs out" do
    @session.acquire_lease("other", ttl: 60)

    freeze_time do
      assert_enqueued_with(job: ManagedAgents::SessionJob, args: [@session, ManagedAgents::SessionJob::RETRIES_WHILE_BUSY + 1], at: 61.seconds.from_now) do
        ManagedAgents::SessionJob.perform_now(@session, ManagedAgents::SessionJob::RETRIES_WHILE_BUSY)
      end
    end
  end

  test "takes over a session whose follower died with its process" do
    @session.acquire_lease("dead", ttl: 60)
    anthropic.respond_with agent_message("Done."), idle

    travel 61.seconds do
      ManagedAgents::SessionJob.perform_now(@session, ManagedAgents::SessionJob::RETRIES_WHILE_BUSY + 1)
    end

    assert @session.reload.settled?
  end

  test "gives up when a live follower still holds the session after that" do
    @session.acquire_lease("other", ttl: 60)

    assert_no_enqueued_jobs do
      ManagedAgents::SessionJob.perform_now(@session, ManagedAgents::SessionJob::RETRIES_WHILE_BUSY + 1)
    end
  end

  test "uses the configured queue" do
    ManagedAgents.config.queue = :agents
    assert_equal "agents", ManagedAgents::SessionJob.new(@session).queue_name
  end
end

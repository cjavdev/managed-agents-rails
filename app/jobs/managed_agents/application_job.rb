module ManagedAgents
  class ApplicationJob < ActiveJob::Base
    queue_as { ManagedAgents.config.queue }

    discard_on ActiveJob::DeserializationError

    # Jobs enqueued before the kill switch was turned off finish without
    # calling the API instead of failing and retrying.
    around_perform do |job, block|
      if ManagedAgents.enabled?
        block.call
      else
        ManagedAgents.logger.info("[managed_agents] Paused; skipped #{job.class.name}")
      end
    end
  end
end

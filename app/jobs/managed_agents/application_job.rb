module ManagedAgents
  class ApplicationJob < ActiveJob::Base
    queue_as { ManagedAgents.config.queue }

    discard_on ActiveJob::DeserializationError
  end
end

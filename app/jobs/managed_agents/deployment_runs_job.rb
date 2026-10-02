module ManagedAgents
  # Finds sessions started by scheduled deployments and follows them, for apps
  # that can't receive webhooks. Schedule it every few minutes.
  class DeploymentRunsJob < ApplicationJob
    def perform
      Deployments.poll
    end
  end
end

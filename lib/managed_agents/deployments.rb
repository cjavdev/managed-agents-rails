module ManagedAgents
  # Scheduled deployments start sessions on Anthropic's side. Adopting a run
  # gives that session a local record and a runner, so custom tools declared by
  # the agent are answered by this app.
  module Deployments
    module_function

    def adopt(run)
      run = ManagedAgents.client.beta.deployment_runs.retrieve(run) if run.is_a?(String)
      return if run.session_id.blank?

      resource = Resource.find_by(kind: "deployment", remote_id: run.deployment_id)
      return unless resource

      session = Session.create_with(
        agent_name: resource.agent_name,
        agent_version: run.try(:agent)&.try(:version),
        deployment_key: resource.key,
        status: "running"
      ).find_or_create_by!(remote_id: run.session_id)
      session.run_later if session.previously_new_record?
      session
    rescue ActiveRecord::RecordNotUnique
      Session.find_by(remote_id: run.session_id)
    end

    def poll(limit: 20)
      Resource.where(kind: "deployment").flat_map do |resource|
        runs = ManagedAgents.client.beta.deployment_runs.list(deployment_id: resource.remote_id, limit: limit)
        known = Session.where(remote_id: runs.data.filter_map(&:session_id)).pluck(:remote_id)
        runs.data.reject { |run| run.session_id.blank? || run.session_id.in?(known) }.filter_map { |run| adopt(run) }
      end
    end

    # Fires a deployment now, outside its schedule.
    def run(agent_name, key)
      resource = Resource.lookup(agent_name, "deployment", key) or raise NotSynced.new(agent_name, "deployment #{key}")
      adopt(ManagedAgents.client.beta.deployments.run(resource.remote_id))
    end
  end
end

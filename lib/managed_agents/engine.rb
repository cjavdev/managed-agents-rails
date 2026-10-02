module ManagedAgents
  class Engine < ::Rails::Engine
    isolate_namespace ManagedAgents

    initializer "managed_agents.active_record" do
      ActiveSupport.on_load(:active_record) do
        include ManagedAgents::HasAgentSessions
      end
    end
  end
end

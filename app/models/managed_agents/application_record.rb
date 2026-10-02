module ManagedAgents
  class ApplicationRecord < ManagedAgents.config.record_base_class.safe_constantize || ActiveRecord::Base
    self.abstract_class = true
    self.table_name_prefix = "managed_agents_"
  end
end

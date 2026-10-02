require "rails/generators"

module ManagedAgents
  module Generators
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../../app/views", __dir__)

      desc "Copies the engine's event and status partials into your app so you can change them."

      def copy_views
        directory "managed_agents", "app/views/managed_agents"
      end
    end
  end
end

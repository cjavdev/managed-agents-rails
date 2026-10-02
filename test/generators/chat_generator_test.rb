require "test_helper"
require "generators/managed_agents/chat/chat_generator"
require "generators/managed_agents/views/views_generator"

class ChatGeneratorTest < Rails::Generators::TestCase
  tests ManagedAgents::Generators::ChatGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  GENERATED = %w[
    app/controllers/agent_sessions_controller.rb
    app/controllers/agent_sessions/messages_controller.rb
    app/controllers/agent_sessions/confirmations_controller.rb
    app/controllers/agent_sessions/interrupts_controller.rb
    app/views/agent_sessions/index.html.erb
    app/views/agent_sessions/show.html.erb
    app/views/agent_sessions/_session.html.erb
    app/views/agent_sessions/_composer.html.erb
    app/javascript/controllers/agent_chat_controller.js
    app/assets/stylesheets/managed_agents.css
  ].freeze

  setup do
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  test "generates controllers, views, assets and routes" do
    run_generator

    GENERATED.each { |path| assert_file path }
    assert_file "config/routes.rb" do |routes|
      assert_match "resources :agent_sessions, only: [:index, :show, :create] do", routes
      assert_match "resource :interrupt, only: :create", routes
    end
    assert_file "app/controllers/agent_sessions_controller.rb", /# before_action :authenticate_user!/
  end

  # The dummy app's chat UI is what the integration tests exercise, so it has
  # to be exactly what the generator produces.
  test "the dummy app's chat UI matches the templates" do
    run_generator

    GENERATED.each do |path|
      assert_equal File.read(File.join(destination_root, path)), Rails.root.join(path).read, "#{path} is out of date in test/dummy"
    end
  end
end

class ViewsGeneratorTest < Rails::Generators::TestCase
  tests ManagedAgents::Generators::ViewsGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "copies the engine's partials into the app" do
    run_generator

    assert_file "app/views/managed_agents/events/_event.html.erb"
    assert_file "app/views/managed_agents/events/_tool_use.html.erb"
    assert_file "app/views/managed_agents/sessions/_status.html.erb"
  end
end

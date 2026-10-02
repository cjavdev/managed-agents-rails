require "test_helper"
require "generators/managed_agents/chat/chat_generator"
require "generators/managed_agents/connections/connections_generator"
require "generators/managed_agents/views/views_generator"

class ChatGeneratorTest < Rails::Generators::TestCase
  tests ManagedAgents::Generators::ChatGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  # How the dummy app was generated.
  DUMMY_OPTIONS = ["--owner", "current_user", "--organization", "current_user&.account"].freeze

  GENERATED = %w[
    app/controllers/concerns/agent_access.rb
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
    assert_file "app/controllers/agent_sessions_controller.rb", /agent_sessions\.find\(params\[:id\]\)/
  end

  test "without authentication the owner is nil and the concern says so" do
    run_generator

    assert_file "app/controllers/concerns/agent_access.rb" do |concern|
      assert_match(/def agent_owner\n    nil\n/, concern)
      assert_match "Change it before deploying", concern
      assert_match '{"personal" => agent_owner}.compact', concern
    end
  end

  test "detects Rails' authentication generator and Devise" do
    FileUtils.mkdir_p(File.join(destination_root, "app/controllers/concerns"))
    File.write(File.join(destination_root, "app/controllers/concerns/authentication.rb"), "")
    run_generator
    assert_file "app/controllers/concerns/agent_access.rb", /def agent_owner\n    Current\.user\n/

    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(destination_root, "config/initializers/devise.rb"), "")
    run_generator
    assert_file "app/controllers/concerns/agent_access.rb", /def agent_owner\n    current_user\n/
  end

  test "the owner and the organisation can be given" do
    run_generator ["--owner", "Current.user", "--organization", "Current.account"]

    assert_file "app/controllers/concerns/agent_access.rb" do |concern|
      assert_match(/def agent_owner\n    Current\.user\n/, concern)
      assert_match '{"personal" => agent_owner, "organization" => Current.account}.compact', concern
    end
  end

  # The dummy app's chat UI is what the integration tests exercise, so it has
  # to be exactly what the generator produces.
  test "the dummy app's chat UI matches the templates" do
    run_generator DUMMY_OPTIONS

    GENERATED.each do |path|
      assert_equal File.read(File.join(destination_root, path)), Rails.root.join(path).read, "#{path} is out of date in test/dummy"
    end
  end
end

class ConnectionsGeneratorTest < Rails::Generators::TestCase
  tests ManagedAgents::Generators::ConnectionsGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  GENERATED = %w[
    app/controllers/concerns/agent_access.rb
    app/controllers/agent_connections_controller.rb
    app/views/agent_connections/index.html.erb
    app/assets/stylesheets/managed_agents.css
  ].freeze

  setup do
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  test "generates the controller, view and routes" do
    run_generator

    GENERATED.each { |path| assert_file path }
    assert_file "config/routes.rb" do |routes|
      assert_match "resources :agent_connections, only: [:index, :create, :destroy] do", routes
      assert_match "get :callback, on: :collection", routes
    end
  end

  test "keeps an agent_access concern that is already there" do
    FileUtils.mkdir_p(File.join(destination_root, "app/controllers/concerns"))
    File.write(File.join(destination_root, "app/controllers/concerns/agent_access.rb"), "# mine\n")

    run_generator ["--owner", "someone_else"]

    assert_file "app/controllers/concerns/agent_access.rb", "# mine\n"
  end

  test "the dummy app's connections page matches the templates" do
    run_generator ChatGeneratorTest::DUMMY_OPTIONS

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

require "test_helper"

class OptionalCredentialTest < ActiveSupport::TestCase
  def files(optional: true)
    agent_files("helper").merge("helper/vault.yaml" => <<~YAML)
      display_name: helper
      credentials:
        - display_name: Render
          optional: #{optional}
          auth:
            type: static_bearer
            mcp_server_url: https://mcp.render.example/mcp
            token: {credential: render_example.api_key}
    YAML
  end

  test "an optional credential whose secret is missing is skipped, not a failure" do
    with_agents(files)

    assert_empty ManagedAgents.definition("helper").problems
    changes, output = sync

    assert_equal :skipped, changes.find { |change| change.kind == "credential" }.action
    assert_empty anthropic.calls_to(:"vcrd.create")
    assert_match "1 skipped", output
    assert_equal "optional, not set", ManagedAgents::Sync.new(io: StringIO.new).status.find { |row| row[1].start_with?("credential") }.last
  end

  test "it is created once the secret is set" do
    with_agents(files)
    sync

    ENV["RENDER_EXAMPLE_API_KEY"] = "rnd_1"
    changes, = sync

    assert_equal :create, changes.find { |change| change.kind == "credential" }.action
    assert_equal "rnd_1", anthropic.calls_to(:"vcrd.create").sole.dig(:auth, :token)
  ensure
    ENV.delete("RENDER_EXAMPLE_API_KEY")
  end

  test "a credential that is not optional still fails the sync without its secret" do
    with_agents(files(optional: false))

    assert_match "render_example.api_key", ManagedAgents.definition("helper").problems.join
    assert_raises(ManagedAgents::DefinitionError) { sync }
  end
end

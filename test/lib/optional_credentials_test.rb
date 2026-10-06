require "test_helper"

class OptionalCredentialsTest < ActiveSupport::TestCase
  setup do
    with_agents(agent_files("ops").merge("ops/vault.yaml" => <<~YAML))
      display_name: ops
      credentials:
        - display_name: Render
          optional: true
          auth:
            type: static_bearer
            mcp_server_url: https://mcp.render.example/mcp
            token: {env: OPS_RENDER_TOKEN}
        - display_name: GitHub
          auth:
            type: static_bearer
            mcp_server_url: https://mcp.github.example/mcp
            token: {env: OPS_GITHUB_TOKEN}
    YAML
    ENV["OPS_GITHUB_TOKEN"] = "gh"
  end

  teardown do
    ENV.delete("OPS_GITHUB_TOKEN")
    ENV.delete("OPS_RENDER_TOKEN")
  end

  test "an optional credential without its secret is skipped and the rest syncs" do
    changes, output = sync

    skipped = changes.find { |change| change.key == "https://mcp.render.example/mcp" }
    assert_equal :skipped, skipped.action
    assert_match "1 skipped", output
    assert_equal ["https://mcp.github.example/mcp"], anthropic.calls_to(:"vcrd.create").map { |call| call[:auth][:mcp_server_url] }
    assert_empty ManagedAgents.definition("ops").problems
  end

  test "it is created once the secret is set" do
    sync
    ENV["OPS_RENDER_TOKEN"] = "render"

    changes, = sync

    assert_equal :create, changes.find { |change| change.key == "https://mcp.render.example/mcp" }.action
    refute anthropic.calls_to(:"vcrd.create").last.key?(:optional)
  end

  test "status doesn't call a credential synced when its secret can't be read" do
    ENV["OPS_RENDER_TOKEN"] = "render"
    sync
    ENV.delete("OPS_RENDER_TOKEN")

    rows = ManagedAgents::Sync.new(io: StringIO.new).status
    assert_equal "pending", rows.find { |row| row[1] == "credential https://mcp.render.example/mcp" }.last
  end

  test "a required credential without its secret still fails" do
    ENV.delete("OPS_GITHUB_TOKEN")

    assert_raises(ManagedAgents::DefinitionError) { sync }
  end
end

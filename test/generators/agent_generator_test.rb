require "test_helper"
require "generators/managed_agents/agent/agent_generator"

class AgentGeneratorTest < Rails::Generators::TestCase
  tests ManagedAgents::Generators::AgentGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "scaffolds the definition files and the agent class" do
    run_generator %w[billing_helper]

    assert_file "app/agents/billing_helper/agent.md" do |content|
      assert_match "name: Billing helper", content
      assert_match "model: claude-opus-5-5", content
      assert_match "type: agent_toolset_20260401", content
      assert_match "You are the billing helper agent.", content
    end
    assert_file "app/agents/billing_helper/environment.yaml", /name: dummy-billing-helper-<%= Rails.env %>/
    assert_file "app/agents/billing_helper_agent.rb", /class BillingHelperAgent < ManagedAgents::Agent/
    assert_no_file "app/agents/billing_helper/vault.yaml"
  end

  test "inherits from ApplicationAgent when the app has one" do
    FileUtils.mkdir_p(File.join(destination_root, "app/agents"))
    File.write(File.join(destination_root, "app/agents/application_agent.rb"), "")

    run_generator %w[billing_helper]

    assert_file "app/agents/billing_helper_agent.rb", /class BillingHelperAgent < ApplicationAgent/
  end

  test "a trailing _agent in the name is not doubled" do
    run_generator %w[billing_agent]

    assert_file "app/agents/billing/agent.md"
    assert_file "app/agents/billing_agent.rb", /class BillingAgent </
  end

  test "scaffolds deployments with a schedule guessed from the name" do
    run_generator %w[reporter --deployments daily hourly-title --vault]

    assert_file "app/agents/reporter/deployment-daily.yaml" do |content|
      assert_match 'expression: "0 9 * * *"', content
      assert_match "agent: ./agent.md", content
      assert_match "environment_id: ./environment.yaml", content
      assert_match "vault_ids:\n  - ./vault.yaml", content
    end
    assert_file "app/agents/reporter/deployment-hourly-title.yaml", /expression: "0 \* \* \* \*"/
    assert_file "app/agents/reporter/vault.yaml", /credentials: \[\]/
  end

  test "the scaffold is a valid definition that syncs" do
    run_generator %w[reporter --deployments daily --vault --model claude-haiku-4-5]
    ManagedAgents.config.agents_path = File.join(destination_root, "app/agents")

    definition = ManagedAgents.definition("reporter")
    assert_empty definition.problems
    assert_equal "claude-haiku-4-5", definition.agent_body["model"]
    assert_equal "dummy-reporter-test", definition.environment_body["name"]

    changes = ManagedAgents::Sync.new(backend: :api, io: StringIO.new).apply
    assert_equal %w[vault environment agent deployment], changes.map(&:kind)
  end
end

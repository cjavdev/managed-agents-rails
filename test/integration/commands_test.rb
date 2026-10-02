require "test_helper"
require "open3"

# Runs the real `bin/rails managed_agents:*` commands in the dummy app.
class CommandsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def rails(*, env: {})
    Open3.capture2e({"RAILS_ENV" => "test", "HELPDESK_MCP_TOKEN" => "token-one"}.merge(env),
      "bin/rails", *, chdir: Rails.root.to_s)
  end

  test "check passes for valid definitions" do
    output, status = rails("managed_agents:check")

    assert status.success?, output
    assert_match "1 agent definition(s) look good", output
  end

  test "check fails and explains when a secret is missing" do
    output, status = rails("managed_agents:check", env: {"HELPDESK_MCP_TOKEN" => nil})

    refute status.success?
    assert_match "HELPDESK_MCP_TOKEN", output
  end

  test "status lists every resource and fails while something is not synced" do
    output, status = rails("managed_agents:status")

    refute status.success?
    assert_match(/support_triage\s+deployment daily\s+not synced/, output)
  end

  test "sync --dry-run prints the plan and changes nothing" do
    output, status = rails("managed_agents:sync", "--dry-run", "--backend", "api")

    assert status.success?, output
    assert_match(/create\s+support_triage\s+agent/, output)
    assert_match "Plan (api backend): 5 create", output
    assert_equal 0, ManagedAgents::Resource.count
  end

  test "create scaffolds an agent with the options given" do
    output, status = rails("managed_agents:create", "--name", "scratch_pad", "--deployments", "weekly", "--vault")

    assert status.success?, output
    assert Rails.root.join("app/agents/scratch_pad/agent.md").exist?
    assert Rails.root.join("app/agents/scratch_pad/vault.yaml").exist?
    assert_match 'expression: "0 9 * * 1"', Rails.root.join("app/agents/scratch_pad/deployment-weekly.yaml").read
    assert_match "class ScratchPadAgent < ApplicationAgent", Rails.root.join("app/agents/scratch_pad_agent.rb").read
  ensure
    FileUtils.rm_rf(Rails.root.join("app/agents/scratch_pad"))
    FileUtils.rm_f(Rails.root.join("app/agents/scratch_pad_agent.rb"))
  end

  test "create without a name says what is missing" do
    output, status = rails("managed_agents:create")

    refute status.success?
    assert_match "--name", output
  end
end

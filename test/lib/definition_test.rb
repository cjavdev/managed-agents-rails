require "test_helper"

class DefinitionTest < ActiveSupport::TestCase
  test "finds every agent folder and ignores Ruby files beside them" do
    assert_equal ["support_triage"], ManagedAgents.definitions.map(&:name)
  end

  test "the agent body is the frontmatter plus the Markdown body as the system prompt" do
    body = ManagedAgents.definition("support_triage").agent_body

    assert_equal "Support triage", body["name"]
    assert_equal "claude-opus-5-5", body["model"]
    assert_match "You triage support tickets for Dummy.", body["system"]
  end

  test "files are rendered through ERB" do
    assert_equal "dummy-support-triage-test", ManagedAgents.definition("support_triage").environment_body["name"]
  end

  test "finds a folder by either dashes or underscores" do
    with_agents(agent_files("repo-ops"))

    assert_equal "repo-ops", ManagedAgents.definition("repo_ops").name
    assert_equal "repo-ops", ManagedAgents.definition("repo-ops").name
  end

  test "a missing agent raises a helpful error" do
    error = assert_raises(ManagedAgents::DefinitionError) { ManagedAgents.definition("nope") }
    assert_match "app/agents/nope/agent.md", error.message
  end

  test "deployments are keyed by the part of the file name after deployment-" do
    with_agents(agent_files.merge(
      "helper/deployment-daily.yaml" => "name: Daily\n",
      "helper/deployment-hourly-title.md" => "---\nname: Hourly\n---\n\nRetitle things.\n",
      "helper/deployment.yaml" => "name: Default\n"
    ))

    deployments = ManagedAgents.definition("helper").deployments
    assert_equal %w[daily default hourly-title], deployments.keys.sort
    assert_equal "Retitle things.", deployments["hourly-title"].body
  end

  test "exposes the custom tools declared in agent.md" do
    definition = ManagedAgents.definition("support_triage")

    assert_equal ["set_priority"], definition.custom_tools.map { |tool| tool["name"] }
    assert_equal ["priority"], definition.custom_tool("set_priority").dig("input_schema", "required")
  end

  test "splits vault.yaml into the vault body and its credentials" do
    definition = ManagedAgents.definition("support_triage")

    assert_equal({"display_name" => "dummy-support-triage"}, definition.vault_body)
    assert_equal ["Helpdesk MCP"], definition.credentials.map { |credential| credential["display_name"] }
  end

  test "resolves relative paths to the resource they point at" do
    definition = ManagedAgents.definition("support_triage")
    from = definition.deployment_paths["daily"]

    assert_equal ["support_triage", "agent", ""], definition.resolve_reference("./agent.md", from: from).to_a
    assert_equal ["support_triage", "vault", ""], definition.resolve_reference("./vault.yaml", from: from).to_a
    assert_nil definition.resolve_reference("agent_01abc", from: from)
  end

  test "reports problems instead of raising" do
    with_agents(
      "broken/agent.md" => "---\nname: Broken\n---\n\nNo model.\n",
      "broken/deployment-daily.yaml" => "name: Daily\nagent: ./agent.md\n"
    )

    problems = ManagedAgents.definition("broken").problems
    assert_includes problems, "broken: environment.yaml is missing"
    assert_includes problems, "broken: agent needs a model"
    assert_includes problems, "broken: deployment daily needs environment_id"
    assert_includes problems, "broken: deployment daily needs initial_events or a Markdown body"
  end

  test "invalid YAML is reported with the file path" do
    with_agents(agent_files("bad", agent: "---\nname: [unclosed\n---\n\nHi\n"))

    problems = ManagedAgents.definition("bad").problems
    assert problems.any? { |problem| problem.include?("bad/agent.md") }, problems.inspect
  end

  test "a Markdown file without frontmatter is a definition error" do
    with_agents(agent_files("bad", agent: "Just a prompt.\n"))

    assert_raises(ManagedAgents::DefinitionError) { ManagedAgents.definition("bad").agent }
  end
end

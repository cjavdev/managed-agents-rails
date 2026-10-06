# managed_agents

[Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview) for Rails.

Define agents as files under `app/agents`, sync them to the Claude API the way you run migrations,
keep the remote IDs in your database, start sessions from your app, answer the agent's custom tools
in Ruby, and generate a chat UI.

```ruby
class SupportTriageAgent < ApplicationAgent
  tool :set_priority do |input|
    subject.update!(priority: input[:priority])
    {ok: true}
  end
end

SupportTriageAgent.start("Triage this ticket", subject: ticket)
```

## Installation

```ruby
# Gemfile
gem "managed_agents", github: "cjavdev/managed-agents-rails"
```

```sh
bundle install
bin/rails generate managed_agents:install
bin/rails db:migrate
```

The install generator adds an initializer, a migration, `app/agents/application_agent.rb` and mounts
the engine at `/managed_agents` (for webhooks).

Requires Ruby 3.2+, Rails 7.2+ and the `anthropic` gem 1.72+.

### Credentials

The API key is read from `ENV["ANTHROPIC_API_KEY"]`, then from `credentials.anthropic.api_key`. With
neither set, the SDK falls back to an `ant auth login` profile or workload identity federation.

## Quick start

```sh
bin/rails managed_agents:create --name assistant   # scaffold app/agents/assistant/
bin/rails managed_agents:sync                      # create it in your workspace
bin/rails generate managed_agents:chat             # optional chat UI at /agent_sessions
```

## Defining agents

Each agent is a folder. The file names are the same ones `ant apply` recognises.

```
app/agents/
  application_agent.rb
  support_triage_agent.rb          # optional: tool handlers and callbacks
  support_triage/
    agent.md                       # frontmatter = the agent, body = its system prompt
    environment.yaml               # the container sessions run in
    vault.yaml                     # credentials (optional)
    deployment-daily.yaml          # a scheduled run (optional, any number)
    deployment-hourly-title.yaml
```

```markdown
---
name: Support triage
model: claude-opus-5-5
tools:
  - type: agent_toolset_20260401
  - type: custom
    name: set_priority
    description: Set the priority of the ticket being triaged.
    input_schema:
      type: object
      properties:
        priority: {type: string, enum: [low, normal, high]}
      required: [priority]
---

You triage support tickets. Read the ticket and call set_priority once.
```

- Every file is rendered through ERB before it is parsed, like `database.yml`. Use it for anything
  that differs per environment: `name: myapp-triage-<%= Rails.env %>`.
- Files refer to each other by relative path: `agent: ./agent.md`,
  `environment_id: ./environment.yaml`, `vault_ids: [./vault.yaml]`.
- A deployment can be YAML with `initial_events`, or Markdown whose body is the kickoff message.

### Skills

A custom skill is a folder under the agent's `skills/` with a `SKILL.md` and any files it needs.
List it by path; Anthropic skills are written as the API takes them.

```
app/agents/support_triage/skills/house-style/SKILL.md
app/agents/support_triage/skills/house-style/examples.md
```

```yaml
skills:
  - ./skills/house-style
  - {type: anthropic, skill_id: xlsx}
```

Skills are uploaded before the agents that use them and pinned by version. Changing any file in the
folder uploads a new version and re-pins those agents. `--prune` forgets a deleted skill but leaves it
in the workspace, since agents elsewhere may still pin it.

### Multiagent rosters

A coordinator delegates to roster agents declared beside it as `agent-<role>.md`, and lists them
by path. Roster agents are synced first and pinned by version, so editing one re-pins the
coordinator. They run as threads of the coordinator's sessions, so they have no environment of their
own, and their custom tools are answered by the coordinator's agent class.

```markdown
---
name: Reply desk
model: claude-opus-5-5
multiagent:
  type: coordinator
  agents: [./agent-researcher.md, ./agent-writer.md]
---
```

Scaffold one with either command:

```sh
bin/rails managed_agents:create --name support_triage --deployments daily --vault
bin/rails generate managed_agents:agent support_triage --deployments daily --vault
```

## Syncing

```sh
bin/rails managed_agents:sync            # create or update whatever changed
bin/rails managed_agents:sync --dry-run  # show the plan only
bin/rails managed_agents:status          # synced / pending / not synced / orphaned
bin/rails managed_agents:check           # validate files and tool handlers, no API calls
```

Run `managed_agents:sync` on every deploy, next to `db:migrate`. Remote IDs are stored in the
`managed_agents_resources` table, so each database tracks the workspace it was synced against:
development and production never share IDs, and nothing needs to be committed.

| Flag | Effect |
| --- | --- |
| `--only NAME` | Sync one agent folder |
| `--backend ant\|api` | Choose how to apply (default: `auto`) |
| `--force` | Overwrite a resource that was changed outside the files |
| `--prune` | Archive remote resources whose files were deleted |
| `--adopt` | Take over an existing environment or credential with the same name |

### Backends

- **ant**: used when the [`ant` CLI](https://platform.claude.com/docs/en/cli-sdks-libraries/cli/apply)
  1.34+ is on `PATH`. The rendered files and a lockfile rebuilt from the database go into
  `tmp/managed_agents/build`, `ant apply` runs there, and the lockfile is read back into the
  database. No `claude-lock.json` is committed.
- **api**: used otherwise (most production containers). Resources are created and updated through
  the SDK, and only when the digest of their request body changed.

Whichever backend created a database's rows keeps being used. Moving from `ant` to `api` works;
moving from `api` to `ant` is refused, because `ant apply` cannot adopt resources it did not create
and would make duplicates.

Set `ANTHROPIC_WORKSPACE_ID` (or `config.workspace_id`) and a sync refuses to run against a database
that holds IDs from a different workspace.

## Vault credentials from Rails credentials

```yaml
# app/agents/support_triage/vault.yaml
display_name: support-triage
credentials:
  - display_name: Linear MCP
    auth:
      type: static_bearer
      mcp_server_url: https://mcp.linear.app/mcp
      token: {credential: linear.mcp_token}
  - display_name: Stripe key
    auth:
      type: environment_variable
      secret_name: STRIPE_API_KEY
      secret_value: {env: STRIPE_SECRET_KEY}
      networking: {type: limited, allowed_hosts: [api.stripe.com]}
```

- `{credential: "linear.mcp_token"}` reads `ENV["LINEAR_MCP_TOKEN"]`, then
  `credentials.dig(Rails.env, :linear, :mcp_token)`, then `credentials.dig(:linear, :mcp_token)`.
- `{env: "NAME"}` reads the environment only.
- Mark a credential `optional: true` when some environments don't have its secret: there it is
  skipped with a warning instead of failing the sync.
- A literal value in `token`, `access_token`, `refresh_token`, `client_secret` or `secret_value` is
  rejected, so a secret can't be committed by accident.
- Rotating the secret and syncing again updates the credential in place. Only a keyed digest of the
  secret is stored locally.

The agent's vault is attached to every session it starts, unless the session asks for other vaults.

## Users, organisations and their credentials

The vault in `vault.yaml` is shared by everyone. For credentials that belong to a person or to an
organisation, any record can own a vault, and each session says whose it acts with.

```ruby
class User < ApplicationRecord
  belongs_to :account
  has_agent_sessions as: :owner   # user.agent_sessions
  has_agent_vault                 # personal connections
end

class Account < ApplicationRecord
  has_agent_vault                 # shared service accounts
end
```

### Choosing vaults for a session

`owner:` is who the session belongs to. `vaults:` is whose credentials it uses, in order: when two
vaults hold a credential for the same MCP server, the first one wins.

```ruby
ResearchAgent.start("…", owner: user, vaults: [user, user.account, :agent])  # personal, then shared, then vault.yaml
ResearchAgent.start("…", owner: user, vaults: [user.account])                # the organisation's only
ResearchAgent.start("…", owner: user, vaults: [user])                        # personal only
ResearchAgent.start("…", owner: user, vaults: [])                            # none
```

An entry can be a record, a `ManagedAgents::Vault`, a vault ID, `:agent` (the agent's `vault.yaml`),
`:owner`, or another symbol that is called on the owner (`:account`). A record that has connected
nothing is skipped. Without `vaults:`, a session gets the agent's default, which is `[:agent]`
unless the class declares otherwise:

```ruby
class ResearchAgent < ApplicationAgent
  vaults :owner, :account, :agent
end
```

Personal credentials are only ever attached when asked for, and `:owner` without an `owner:` raises.
Sessions the app starts by itself (jobs, scheduled deployments) should name shared vaults only.

`ResearchAgent.missing_connections(owner: user)` returns the MCP servers the agent declares that no
vault in the chain has a credential for, so you can ask the person to connect them first.

An owner can keep more than one group of credentials: `account.agent_vault!(:billing)`.

### Storing credentials

```ruby
vault = user.agent_vault!   # created on the API the first time
vault.connect_bearer("https://mcp.linear.app/mcp", token: "lin_api_…")
vault.connect_oauth("https://mcp.notion.com/mcp", access_token: "…", refresh_token: "…",
  token_endpoint: "https://…/token", client_id: "…")
vault.connect_env("STRIPE_API_KEY", value: "sk_…", allowed_hosts: ["api.stripe.com"])
vault.connected?("https://mcp.linear.app/mcp")
vault.disconnect("https://mcp.linear.app/mcp")
```

Secrets go straight to the vault; the local `managed_agents_connections` row keeps only what
identifies the credential and its status. Connecting again rotates the credential in place.
Destroying the owner archives its vaults.

### Connecting MCP servers with OAuth

```sh
bin/rails generate managed_agents:connections --organization "current_user.account"
```

generates `/agent_connections`: every MCP server your agents declare, with Connect, Reconnect and
Disconnect for each group of credentials the person may manage (or a field to paste a token).
Connect runs the MCP authorization flow: discovery of the server's authorization server, dynamic
client registration, PKCE, and the token exchange. The tokens are stored with their refresh
settings so Anthropic keeps them fresh.

The same flow is available to your own controllers:

```ruby
pending = ManagedAgents::OAuth.authorize(server_url, redirect_uri: callback_url)
session[:agent_connection] = pending.to_h
redirect_to pending.url, allow_other_host: true

# in the callback
ManagedAgents::OAuth.complete(current_user, session.delete(:agent_connection), params)
```

Servers that don't offer dynamic client registration need a client of your own:

```ruby
config.oauth_clients = {
  "https://mcp.slack.com/mcp" => {client_id: "…", client_secret: "…", scope: "channels:read"}
}
```

When a refresh token stops working, the `vault_credential.refresh_failed` webhook marks the
connection as needing to be reconnected, and it no longer counts as connected.

### Who can see what

The generated controllers look everything up through `app/controllers/concerns/agent_access.rb`:

```ruby
def agent_owner = current_user                      # sessions are scoped to this record
def agent_vault_owners                              # whose credentials this person may manage
  {"personal" => agent_owner, "organization" => current_user.account}.compact
end
```

The generators fill in `Current.user` or `current_user` when they find Rails' authentication
generator or Devise, and accept `--owner` and `--organization`. Tool handlers have `owner` next to
`subject`, to scope what the agent may touch:

```ruby
tool :find_ticket do |input|
  owner.account.tickets.find(input[:id]).as_json
end
```

Vaults are workspace-wide on the API (any session can attach any vault ID), so this scoping is what
keeps tenants apart.

## Running sessions

```ruby
session = SupportTriageAgent.start("Triage this ticket",
  subject: ticket,          # any record; available to tool handlers as `subject`
  title: "Ticket #42",
  max_cost: 2.00)           # hard spend cap in dollars

session.send_message("Also check the billing history")
session.interrupt!
session.last_agent_message
session.console_url
```

`start` creates the session, stores a `ManagedAgents::Session` and enqueues
`ManagedAgents::SessionJob`, which holds the event stream until the agent's turn ends. Every event
is stored in `managed_agents_events`.

```ruby
class Ticket < ApplicationRecord
  has_agent_sessions   # ticket.agent_sessions
end
```

An agent with no Ruby class still works: `ManagedAgents.agent("assistant").start("Hello")`.

### Custom tools

Declare the tool's schema in `agent.md` and handle it in the agent class. The block runs in your
app with `session` and `subject` available; its return value is what the agent reads.

```ruby
class SupportTriageAgent < ApplicationAgent
  tool :set_priority do |input|
    raise ManagedAgents::ToolError, "Ticket is closed" if subject.closed?

    subject.update!(priority: input[:priority])
    {ok: true}
  end

  after_turn { subject.update!(summary: session.last_agent_message) }
  on_error { |event| Rails.logger.warn(event.error_message) }
end
```

- Input is checked against the `input_schema` before the handler runs.
- `ToolError` and unexpected exceptions are returned to the agent as error results; unexpected ones
  are also reported through `Rails.error`.
- A tool call is answered once per call ID, including after a crash and replay. Handlers can still
  run twice if the process dies between running the handler and sending the result, so keep them
  idempotent.
  `tool_use_id` is the call's ID inside a handler, and stays the same when the call is answered
  again, so it can key an idempotent write.
- `self.validate_tool_input = false` skips the schema check, for handlers that validate input
  themselves.

### Limits, events and cleanup

For agents that do one job per session, unattended:

```ruby
class NightlyReportAgent < ApplicationAgent
  # Interrupt a turn that runs longer than this, counted from the message
  # that started it. A block is evaluated on the agent instance.
  self.max_turn_duration = 30.minutes

  # Archive the session when its turn ends, so it holds no container.
  self.archive_after_turn = true

  # Every event the runner reads, once, before a custom tool call is
  # answered. Narrow it with event types.
  on_event("span.model_request_end") do |event|
    spent = subject.record_usage!(event.payload["model_usage"])
    interrupt!(:budget) if spent > subject.budget
  end

  # Why the turn was stopped: :deadline, or what was passed to interrupt!.
  on_interrupt { |reason| subject.update!(stop_reason: reason) }
end
```

`max_cost` on `start` is the platform's own cap; `on_event` is for anything finer. While a turn has
a deadline, the stream is never held past it, so an agent that has gone quiet is still interrupted
on time.

### Scheduled deployments

Deployments run on Anthropic's side. To let those sessions use your custom tools, either register a
webhook (below) or schedule `ManagedAgents::DeploymentRunsJob` every few minutes. Both give each
fired session a local record and a runner. `SupportTriageAgent.run_deployment(:daily)` fires one now.

### Webhooks

Register `https://your-app/managed_agents/webhooks` in the Console and set the signing secret as
`ANTHROPIC_WEBHOOK_SIGNING_KEY`, `credentials.anthropic.webhook_secret` or `config.webhook_secret`.
Deliveries are verified, then handled in a job. Subscribe to the rest yourself:

```ruby
ActiveSupport::Notifications.subscribe("webhook.managed_agents") do |event|
  event.payload # => {type: "vault_credential.refresh_failed", id: "vcrd_..."}
end
```

### Pausing every API call

```ruby
# config/initializers/managed_agents.rb
ManagedAgents.configure do |config|
  config.enabled = -> { ENV["MANAGED_AGENTS_ENABLED"] == "true" }
end
```

While `enabled` is false, `ManagedAgents.client` raises `ManagedAgents::Paused`, the engine's jobs
finish without calling the API, webhook deliveries are acknowledged and dropped, and `sync` refuses to
run (`status`, `check` and `--dry-run` still work). A callable is checked on every call.

### Queues

A `SessionJob` lasts as long as the agent's turn. Give it a queue with spare threads
(`config.queue = :agents`).

## Chat UI

```sh
bin/rails generate managed_agents:chat
```

Generates `AgentSessionsController` (plus nested controllers for messages, tool approvals and
interrupt), views, a Stimulus controller and a plain-CSS stylesheet. The code is yours to change.
Sessions are scoped to `agent_owner` (see [Who can see what](#who-can-see-what)). **If no
authentication is detected, `agent_owner` is nil and sessions are not scoped to a person**: set it
before deploying.

The transcript shows messages, tool calls with their input and results, approval prompts for tools
with an `always_ask` policy, and streams assistant text while it is written. Live updates use Turbo
Streams over Action Cable and need `turbo-rails`.

`bin/rails generate managed_agents:views` copies the event partials into your app.

## Testing your agents

```ruby
require "managed_agents/testing"

class SupportTriageAgentTest < ActiveSupport::TestCase
  include ManagedAgents::Testing::Helper

  test "sets the priority the agent asks for" do
    sync_agents
    anthropic.respond_with custom_tool_use("set_priority", priority: "high"), agent_message("Done."), idle

    session = SupportTriageAgent.start("Triage", subject: tickets(:refund), run: false)
    session.run_now

    assert_equal "high", tickets(:refund).reload.priority
    assert_equal false, anthropic.tool_results.sole[:is_error]
  end
end
```

The helper swaps in an in-memory client for each test. `anthropic.calls` records what was sent.

## Example apps

- [`examples/kanban`](examples/kanban): a small Trello-style board with an assistant that creates
  and moves cards.
- [`examples/helpdesk`](examples/helpdesk): support tickets triaged by an agent when they arrive,
  with a daily digest deployment.

## Not covered yet

Memory stores as files, per-tenant agent definitions or overrides,
outcomes, and self-hosted sandboxes.

## Development

```sh
bin/rails test          # tests run against test/dummy
bundle exec standardrb
```

## License

MIT.

# Changelog

## Unreleased

- Agent definitions under `app/agents/<name>/`, rendered through ERB.
- `managed_agents:create`, `sync`, `status` and `check` commands.
- Sync through `ant apply` or the API, with remote IDs stored in the database.
- Vault credentials resolved from Rails credentials or ENV.
- Sessions, events, custom tool handlers and callbacks.
- Webhook endpoint and adoption of sessions started by scheduled deployments.
- Generators: `install`, `agent`, `chat` and `views`.
- `ManagedAgents::Testing` fake client for app tests.
- Sessions have an `owner`; the generated chat UI only shows a person their own.
- Vaults owned by any record (`has_agent_vault`), combined per session with `vaults:`.
- MCP OAuth connect flow and a `connections` generator.
- Agents can share another agent's environment with `environment: ../other/environment.yaml`.
- `max_turn_duration`, `on_event`, `on_interrupt` and `archive_after_turn` on agents; `interrupt!` from callbacks.
- `tool_use_id` in tool handlers; `validate_tool_input` to skip the schema check.
- `config.enabled` kill switch: while off, the client raises `ManagedAgents::Paused`, engine jobs skip and webhooks are dropped.
- `optional: true` on a vault credential skips it when its secret isn't set.
- Multiagent rosters: `agent-<role>.md` files referenced from a coordinator's `multiagent.agents`.
- Custom skills as `skills/<name>/` folders, uploaded and pinned by version.

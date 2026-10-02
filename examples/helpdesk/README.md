# Helpdesk example

Support tickets triaged by an agent as they arrive. The agent classifies each ticket (priority,
category, team, summary), drafts a first reply for a person to review, and writes a digest of the
open queue every weekday morning from a scheduled deployment.

```sh
bundle install
bin/rails db:prepare          # creates the database and three sample tickets
bin/rails managed_agents:sync # creates the agent, environment, vault and deployment
bin/rails server
```

Create a ticket and watch the triage fill in, or open a sample ticket and press "Triage again".
"Write it now" on the inbox fires the digest deployment immediately.

Where to look:

- `app/agents/ticket_triage/`: the agent, its environment, an empty vault with an example
  credential mapping, and `deployment-daily.yaml`.
- `app/agents/ticket_triage_agent.rb`: five tool handlers.
- `app/models/ticket.rb`: `Ticket#triage` starts the session; the prompt wraps the customer's text
  so it is treated as data.
- `app/views/tickets/show.html.erb`: triage results and agent activity, both updated live.
- `test/`: model, agent and end-to-end tests using `ManagedAgents::Testing`.

## Scheduled runs

The digest deployment's sessions are started by Anthropic. For this app to answer their tool calls
it has to learn about each run, in one of two ways:

- Register `https://<host>/managed_agents/webhooks` in the Console (Manage > Webhooks), subscribe to
  `deployment_run.succeeded`, and set `ANTHROPIC_WEBHOOK_SIGNING_KEY`.
- Or run `ManagedAgents::DeploymentRunsJob` every few minutes from your scheduler.

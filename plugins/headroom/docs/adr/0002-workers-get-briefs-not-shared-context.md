# Workers get a brief, not the orchestrator's context

A worker spawn gets a written brief and nothing else: GOAL, CONTEXT, SCOPE and RETURN, plus a report-file path. It never sees the orchestrator's own context. Cognition's essay "Don't build multi-agents" argues against exactly this: subagents working from partial context make conflicting decisions, and agents should share the full trace instead. headroom keeps briefs anyway because the primitive that would share context, `subagent_type: "fork"`, always inherits the orchestrator's model and ignores the `model` parameter, and because a worker's own intermediate output staying out of the main context is the entire reason to delegate.

## Considered Options

- **`subagent_type: "fork"`, sharing the orchestrator's context.** Gives a worker everything the orchestrator has, but check-agent.sh's fork branch denies it because it inherits the orchestrator's model unconditionally and ignores `model`, undoing each role's own default.
- **Paste the orchestrator's relevant context into the brief.** Keeps the model choice, but a brief that grows to hold context drifts as the orchestrator's own context changes, and pastes in the very intermediate output delegation exists to keep out.

## Consequences

- A worker acting on a stale or incomplete brief can make a call the orchestrator, with full context, would have made differently; this is the risk the essay names and headroom accepts.
- Escalation continues the same worker with `SendMessage` rather than starting over from a blank brief, and a multi-worker brief points at a spec or plan file by path instead of restating it; both narrow the gap without sharing context outright.
- Revisit this decision if `fork` ever accepts a `model` parameter.

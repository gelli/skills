# model-routing

Keeps the orchestrator on the session's top-tier model and pushes the doing down to the cheapest subagent tier that can do it reliably. Two hooks:

- **SessionStart** injects `routing.md` into context on startup, clear and after every compaction. Not on resume: a resumed transcript already holds the rules. The rules pre-authorise Haiku, Sonnet and Opus spawns, workflows and deep research (no confirmation prompt), and define the Haiku / Sonnet / Opus tiers, the gated Opus-subagent exception, the brief every delegation must carry, and the Fable orchestrator-only rule.
- **PreToolUse on `Agent`** denies a spawn that would land on the orchestrator model and tells Claude why so it re-issues the call correctly:
  - no `model` parameter (the subagent would inherit the session model)
  - `model: "fable"` (Fable is orchestrator-only)
  - `subagent_type: "fork"` (forks always inherit the parent model and ignore `model`)

Everything else passes through. Whether `opus` is justified for a given spawn is a judgment call the rules leave to Claude, so the hook does not gate it.

The guard is deliberately independent of which model the session runs on: hook input carries no session model, and an omitted `model` is a routing bug under Opus and Fable alike.

## Install

```
/plugin marketplace add gelli/skills
/plugin install model-routing@gelli-skills
```

If your `CLAUDE.md` still includes a copy of the routing rules, remove it after installing. The plugin ships the pre-authorisation along with the rules, so drop that from `CLAUDE.md` too. Keep environment-specific policy there, such as routing to agents that only exist on your machine (for example a browser-automation agent).

## Requirements

The guard parses hook input with `jq`, falling back to `python3`. With neither installed it lets the call through and logs a note on stderr.


## Test

```
sh plugins/model-routing/tests/test-hooks.sh
claude plugin validate ./plugins/model-routing --strict
```

## Try it in a session

```
claude --plugin-dir ./plugins/model-routing
```

Then ask Claude to spawn a subagent without a model. The call is refused with the reason and re-issued with an explicit model.

## Recommended Sources

### Foundational (Anthropic)
- [Building Effective Agents](https://www.anthropic.com/research/building-effective-agents) — Anthropic
  Defines the core workflow taxonomy: prompt chaining, routing, parallelization, orchestrator-workers, evaluator-optimizer.
- [How we built our multi-agent research system](https://www.anthropic.com/engineering/built-multi-agent-research-system) — Anthropic Engineering
  Production playbook for the orchestrator-worker pattern behind Claude's Research feature (90% quality gain, 15x token cost).

### Independent / Practitioner
- [Simon Willison's Weblog](https://simonwillison.net/) — Simon Willison
  Most consistently trusted independent voice on agentic engineering practice; tracks routing and tool-use patterns in near-real-time.
- [obra/superpowers](https://github.com/obra/superpowers) — Jesse Vincent (GitHub)
  Widely-adopted Claude Code plugin implementing brainstorm → plan → subagent-driven-development as a real orchestration workflow.
- [Best Practices for Claude Code Subagents](https://www.pubnub.com/blog/best-practices-for-claude-code-sub-agents/) — PubNub Engineering
  Production writeup of a PM → architect → implementer subagent pipeline, with hooks and MCP-based review gates.
- [Claude Code Subagents: Setup, Config, and When to Use Them](https://www.glukhov.org/ai-devtools/claude-code/claude-code-subagents/) — Rost Glukhov
  Practical guidance on when subagents earn their keep vs. overkill, plus common failure modes.

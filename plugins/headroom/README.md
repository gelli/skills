# headroom

Keeps the orchestrator's context small. The main session reads and edits less itself and hands lookups, runs and implementation to cheaper subagents. Headroom replaces model-routing and the earlier headroom plugin.

## What it does

Four hooks and one agent:

- **SessionStart** injects `rules.md` on startup, clear and after every compaction. The rules pre-authorise Haiku, Sonnet and Opus spawns, workflows and deep research (no confirmation prompt), and define the tiers, review routing, the brief every delegation carries, a Reading section (when to hand reading to the scout) and the Fable orchestrator-only rule.
- **PreToolUse on `Agent`** denies a spawn that would land on the orchestrator model: no `model` parameter, `model: "fable"`, or `subagent_type: "fork"`. The denial names the allowed models so Claude re-issues the call. The `headroom:scout` agent passes without a `model` because it pins Haiku itself.
- **PreToolUse on `Workflow`** reads the script (inline `script` or the file at `scriptPath`) and denies one that names `fable` or `mythos`, or holds an `agent(` call whose options name no `model`. The denial tells Claude to write `haiku`, `sonnet` or `opus` literally in each call.
- **PostToolUse** (`budget.sh`) keeps two counters for the main session and nudges once per user prompt for each:
  - Reading: when read output since the prompt passes the reading budget, the nudge names `headroom:scout`. Read, Grep, Glob, WebFetch, WebSearch, MCP tools and Bash count. Bash counts stdout plus stderr, and nothing once the output is persisted to a file.
  - Doing: when the main session edits a third distinct file in the prompt (Edit, Write, NotebookEdit), the nudge names an implementer spawn.
  Both counters restart when the hook input carries a new `prompt_id`. Worker tool calls (hook input with an `agent_id`) never count.
- **`headroom:scout`** is a Haiku agent for single-shape jobs: repo-wide searches, test and build runs, log reads, multi-file reads, docs lookups, summaries. It has no Edit, Write, NotebookEdit, Agent or Workflow tool and reports in 40 lines or less.

Nothing blocks except the Agent and Workflow checks. The plugin writes no log; measurement comes from transcripts.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `HEADROOM_READ_BUDGET` | `24576` | Bytes of read output per prompt before the reading nudge. `0` turns it off. |
| `HEADROOM_EDIT_BUDGET` | `3` | Distinct files edited per prompt before the doing nudge. `0` turns it off. |

Counter state is one small file per session in `CLAUDE_PLUGIN_DATA`.

## Requirements

Hooks are POSIX `sh` and parse hook input with `jq`, falling back to `python3`. With neither installed, every hook lets the call through and writes one line to stderr.

## Install

```
/plugin marketplace add gelli/skills
/plugin install headroom@gelli-skills
```

If your `CLAUDE.md` still includes a copy of the routing rules, remove it after installing. The plugin ships the pre-authorisation along with the rules. Keep environment-specific policy in `CLAUDE.md`, such as routing to agents that only exist on your machine.

### Migrating from model-routing

Both plugins hook `PreToolUse` on `Agent` and their checks conflict, so remove model-routing first:

```
/plugin uninstall model-routing@gelli-skills
/plugin install headroom@gelli-skills
```

Then set `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in your environment, so subagents that omit a model land on Sonnet.

## Limits

The Workflow check is a text heuristic. A model passed through a variable (`agent(prompt, { model: m })`) triggers a false denial, and a script that builds its `agent()` calls dynamically can escape the check. The denial message asks for the model written literally in each call. The doing budget counts Edit, Write and NotebookEdit only; edits through Bash (`sed -i`, heredocs) stay uncounted.

## Test

```
sh plugins/headroom/tests/test-hooks.sh
HEADROOM_PARSER=python3 sh plugins/headroom/tests/test-hooks.sh
claude plugin validate ./plugins/headroom --strict
```

The script already runs the python3 path for each hook, so the second line repeats the matrix with python3 as the parser everywhere.

## Try it in a session

```
claude --plugin-dir ./plugins/headroom
```

Ask Claude to spawn a subagent without a model: the call is refused with the reason and re-issued with an explicit model. Read several large files in one prompt to see the reading nudge.

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

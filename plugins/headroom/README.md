# headroom

Keeps the orchestrator's context small by delegating token-heavy work to workers, instead of routing by model tier alone. Context hygiene comes first, then quality, then cost: a scout that reads five files and returns a two-line summary saves the main context far more than it saves in dollars.

## Roles

| Role | Model | Effort | Tools | Raisable to |
|---|---|---|---|---|
| `headroom:scout` | haiku | (none; Haiku rejects it) | no Edit/Write/NotebookEdit, plus Bash for test/build/lint runs | sonnet, for multi-step research |
| `headroom:implementer` | sonnet | high | full, minus Agent/Workflow | opus, for escalation |
| `headroom:reviewer` | sonnet | high | no Edit/Write/NotebookEdit, plus Bash to run things | opus, for the final whole-branch review or a hard investigation |

Scout and reviewer both carry Bash: a scout runs tests and builds, a reviewer runs the code under review. Neither may use Edit, Write, or NotebookEdit, enforced by `disallowedTools`; the one write either is allowed is its own report file, made with Bash and confined to the scratch directory named in its brief. They change no other project files.

A spawn may only raise a role's default model, never lower it, and never pass `fable` or `inherit`, or `subagent_type: "fork"`. See `rules.md`, injected at session start, for the full rule set.

## What the hooks do

- **SessionStart** injects `rules.md` into context on startup, clear, and after compaction.
- **UserPromptSubmit** watches for `/headroom:inline` and records a one-call or session-long lift of the blocks.
- **PreToolUse on `Agent`** enforces the role/model rule above.
- **PreToolUse on `Workflow`** refuses a workflow that asks for `fable` or `mythos` as a model.
- **PreToolUse on `Bash`/`Grep`** (only when `hard_blocks` is on) refuses delegable work in the main session: test/build/lint/type-check commands, and repo-wide searches. Grep counts as repo-wide when it has no path (or the project root) and no glob filter; there is no documented `type` (file-type) field on Grep's tool input to also exempt, so a type-scoped Grep with no glob is still treated as repo-wide. Worker calls are never blocked. Glob is never blocked here: it is the cheapest lookup there is, and `nudge.sh` still covers a large Glob result.
- **PostToolUse** nudges the main session when a tool result was large (roughly 8k tokens), pointing at `headroom:scout` for next time.
- **SubagentStop** talks to the worker, not the main session: if its own report ran long, this blocks it from stopping and asks it to resend a shorter report with a report file. If a background worker delivers its report through a hand-back, this hook only sees the worker's closing text and then does nothing. Background workers are the default in current Claude Code, so in most sessions the 40-line limit rests on the agent instructions, not on this hook.

Known limitation: the Bash block reads commands as text. A `<<WORD` inside a quoted string is taken for a heredoc, so a real command on the following lines can slip through unblocked.

## Settings

- `hard_blocks` (default off): refuse delegable work in the main session instead of just nudging. Lift it for one call or the rest of a session with `/headroom:inline` or `/headroom:inline session`.
- `block_patterns`: extra extended-regex patterns, matched the same way as the built-in list, for commands specific to your repo.
- `HEADROOM_BLOCKS=0`: an environment kill switch that disables blocking outright, independent of `hard_blocks`.

Recommended: set `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` as a fallback for any agent spawned without an explicit model, including workflow agents that don't name one; headroom's own three roles always carry a default and don't need it.

## Logs

Every deny, block, override, nudge, and report warning is appended as one JSON line to `${CLAUDE_PLUGIN_DATA}/headroom.log.jsonl`.

## Migrating from model-routing

Uninstall `model-routing` before installing headroom. Both plugins hook `PreToolUse` on `Agent` and enforce their own model rule; model-routing's check does not know about headroom's roles and will refuse a `headroom:scout`/`implementer`/`reviewer` spawn that omits `model` even when headroom's own rule would allow it. If you kept machine-specific model routing in `CLAUDE.md` (for example, routing to an agent that only exists on one machine), keep that; headroom replaces the tier rules, not local policy.

## Requirements

`jq`, or `python3` as a fallback. With neither, a hook allows the call through and prints a one-line note on stderr.

## Install

```
/plugin marketplace add gelli/skills
/plugin install headroom@gelli-skills
```

## Test

```
sh plugins/headroom/tests/test-hooks.sh
claude plugin validate ./plugins/headroom --strict
```

## Try it

```
claude --plugin-dir ./plugins/headroom
```

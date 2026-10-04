# headroom

Keeps the orchestrator's context small by delegating token-heavy work to workers, instead of routing by model tier alone. Context hygiene comes first, then quality, then cost: a scout that reads five files and returns a two-line summary saves the main context far more than it saves in dollars.

## Roles

| Role | Model | Effort | Tools | Raisable to |
|---|---|---|---|---|
| `headroom:scout` | haiku | (none; Haiku rejects it) | no Edit/Write/NotebookEdit, plus Bash for test/build/lint runs; `maxTurns: 30` | sonnet, for a judgment (why, whether), not a lookup (where, what, run this) |
| `headroom:implementer` | sonnet | high | full, minus Agent/Workflow; `maxTurns: 80` | opus, for escalation |
| `headroom:reviewer` | sonnet | high | tools allowlist: Read, Grep, Glob, Bash, WebFetch, WebSearch (no MCP) | opus, for the final whole-branch review or a hard investigation |

Scout and reviewer both carry Bash: a scout runs tests and builds, a reviewer runs the code under review. The ban on Edit, Write, and NotebookEdit is enforced for scout by `disallowedTools`, and for reviewer twice over, by a `tools` allowlist with `disallowedTools` kept as a backstop. Beyond that, "changes no project files" rests on each role's instructions, not on enforcement: scout has Bash and MCP tools, reviewer has Bash, both used read-only by instruction. The one write either is allowed is its own report file, made with Bash and confined to the scratch directory named in its brief.

A spawn may only raise a role's default model, never lower it, and never pass `fable`, `inherit`, `subagent_type: "fork"`, or `name`: `name` would turn a role into an agent-teams teammate rather than a worker, and a teammate may not keep `disallowedTools`. See `rules.md`, injected at session start, for the full rule set.

Explore and Plan are not headroom roles: they go through the check's fork, fable/mythos, and inherit denials, the role/model-rank check doesn't apply, and a spawn that omits `model` is denied (like general-purpose), because Explore otherwise inherits the main session's model, capped at Opus; that is why `rules.md` prefers `headroom:scout` for search and lookup work. To rule Explore out entirely rather than just discourage it, add `permissions.deny: ["Agent(Explore)"]` to your settings; that's Claude Code's own mechanism, not something headroom enforces.

## What the hooks do

- **SessionStart** injects `rules.md` into context on startup, clear, and after compaction.
- **UserPromptSubmit** watches for `/headroom:inline` and records a one-call or session-long lift of the blocks.
- **PreToolUse on `Agent`** enforces the role/model rule above, including the `name` check, and logs every allowed spawn (role, model, raised or default, isolation, background) alongside denies.
- **PreToolUse on `Read`** (on by default, not tied to `hard_blocks`) refuses a Read in the main session of a file at or over `read_max_bytes` (default 32,768 bytes, the nudge threshold) unless the Read sets `limit` to 400 lines or fewer. Images and PDFs, missing files, and workers' own Reads are never refused. The reason states the size and offers three ways out: delegate to `headroom:scout` with a specific question, Read a targeted `offset`/`limit` range, or ask the user for `/headroom:inline`. This is a deliberate exception to "blocks are opt-in": a whole large file is the biggest avoidable context cost, and the nudge only speaks after the bytes are in. Set `read_max_bytes` to 0 to turn it off.
- **Workflows** are not a hook: `rules.md` tells the session to run the Workflow tool without asking for 3+ independent parallel subtasks or a staged pipeline, and the pre-authorisation clause counts installing headroom as the user's request for it, within the session's workflow size guideline. `/effort ultracode` is the manual override.
- **PreToolUse on `Workflow`** refuses a workflow that asks for `fable` or `mythos` as a model.
- **PreToolUse on `Bash`/`Grep`** (only when `hard_blocks` is on) refuses delegable work in the main session: test/build/lint/type-check commands, and repo-wide searches. Grep counts as repo-wide when it has no path (or the project root) and no glob filter; there is no documented `type` (file-type) field on Grep's tool input to also exempt, so a type-scoped Grep with no glob is still treated as repo-wide. Worker calls are never blocked. Glob is never blocked here: it is the cheapest lookup there is, and `nudge.sh` still covers a large Glob result.
- **PostToolUse** on `Read|Bash|Grep|Glob|WebFetch|WebSearch|mcp__.*` nudges the main session once a tool result was large enough to be worth delegating next time, pointing at `headroom:scout`, and logs the tool name and size. It measures what the model actually took in, not the raw tool response: for Bash, `stdout` + `stderr`, skipped entirely once the output is persisted, since the model then only saw a ~2KB preview and a path; for Read, `file.content`; for everything else, the tool response's own size as compact JSON. Threshold: 32,768 bytes, roughly 8k tokens.
- **SubagentStop** logs one usage line per worker stop, for every agent type, with model, turn count, token usage summed over the worker's transcript, and report size; this is what feeds the worker-usage side of `headroom.log.jsonl`. It also talks to the worker itself, not the main session: when a `headroom:*` role's own report runs past 60 lines or 8000 bytes (a tolerance above the 40-line rule in its instructions), this blocks it from stopping and asks it to resend a shorter report with a report file. It sees the worker's full report in `last_assistant_message` even for a background worker delivering through a hand-back; the block itself is limited to headroom's own roles, so Explore and other plugins' agents are logged but never blocked.
- **Stop** logs the main session's own context size once per turn: from the tail of its transcript, the input, cache-read, and cache-write tokens of the last assistant entry that carries usage, plus model.

Known limitation of both usage lines: Claude Code can run these hooks before it has written the final assistant entry to the transcript, and a single read then misses the last API call (the Stop line shows the previous call's context size; the worker line undercounts by up to one whole call). Both hooks therefore re-read the transcript's tail every 0.1 s, for up to about 2 s (Stop) or 3 s (SubagentStop), until its last text entry equals the hook input's `last_assistant_message` with no user entry after it. Each line carries `complete`: `true` when that final entry was seen, `false` when the wait ran out or there was no message to match. A `complete: false` line holds stale numbers; `usage.sh` does not filter it out yet. Even a `complete: true` line takes `output_tokens` as the transcript records it, and Claude Code sometimes writes the final message's entry mid-stream (one observed worker's final entry reads 2 output tokens), so the last call's output count can be low. The race was only observed in `-p` (headless) sessions; interactive mode is untested.

Known limitation: the Bash block reads commands as text. A `<<WORD` inside a quoted string is taken for a heredoc, so a real command on the following lines can slip through unblocked.

## Settings

- `read_max_bytes` (default 32768, on by default): the main session may not Read a file at or over this many bytes without a `limit` of 400 or fewer. `0` turns the check off. Lifted by `/headroom:inline` and `HEADROOM_BLOCKS=0` like the other blocks.
- `hard_blocks` (default off): refuse delegable work in the main session instead of just nudging. This refuses even a single targeted test run, not only a full suite or build. Lift it for one call or the rest of a session with `/headroom:inline` or `/headroom:inline session`.
- `block_patterns`: extra extended-regex patterns, matched the same way as the built-in list, for commands specific to your repo. Not a safety guard; see Safety below.
- `HEADROOM_BLOCKS=0`: an environment kill switch that disables blocking outright (including the Read check), independent of `hard_blocks`.

Recommended: set `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` as a fallback for any agent spawned without an explicit model, including workflow agents that don't name one; headroom's own three roles always carry a default and don't need it. Also recommended: set `"worktree": {"baseRef": "head"}` in your settings.json, so any Agent call that sets `isolation: "worktree"` picks it up. The default, `"fresh"`, branches the worktree from the repo's default branch, so an isolated worker won't see this branch's commits unless you say `"head"`.

## Safety

headroom is not a security boundary. Blocking applies only to the main session, only while `hard_blocks` is on (the large-file Read check is the one exception: it is on unless `read_max_bytes` is 0), and the user can lift it at any time with `/headroom:inline` or `HEADROOM_BLOCKS=0`; nudges are advice and never stop anything. A worker's tool limits hold only as far as Claude Code enforces `tools` and `disallowedTools`, and scout and reviewer both still carry Bash. For anything that must not run at all, regardless of role, use `/sandbox` or `permissions.deny` instead.

## Logs

Every deny, block (including a large-file Read refusal: tool name, file size in bytes, path; otherwise tool name and the triggering command's byte count, 0 for Grep), override, allowed spawn, nudge (tool name and bytes), worker stop (model, turns, summed tokens, report size, `complete`), report-length block when one fires (agent type, lines/bytes), and main-session turn (context size, `complete`) is appended as one JSON line to `${CLAUDE_PLUGIN_DATA}/headroom.log.jsonl`. Under a normal plugin install that path sits under Claude Code's own plugin data directory; loaded with `--plugin-dir`, as under Try it below, it's `~/.claude/plugins/data/headroom-inline/headroom.log.jsonl`, shared by every headroom instance loaded that way. The file is capped at 10MB: the next write past that rotates it to `headroom.log.jsonl.1` first (overwriting any older one), so it never grows without bound. `usage.sh` and any ad hoc `jq`/`grep` over the log only read the live file; pass `headroom.log.jsonl.1` explicitly to look further back.

Run `sh plugins/headroom/scripts/usage.sh [--window 5h|7d|all] [log-path]` (default window 7d; the log path falls back to `$CLAUDE_PLUGIN_DATA`, then the newest `~/.claude/plugins/data/headroom*/headroom.log.jsonl`) for a summary: worker spawns and tokens grouped by agent_type and model, for every agent type the log has, not just headroom's own roles, so Explore and other plugins' agents show up too, tokens per report byte, the main session's latest and peak context size, counts of nudges/blocks/denies/raised spawns, and any session that got a nudge but never spawned a worker.

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

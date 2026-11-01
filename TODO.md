# TODO

## headroom

Measure first, then change enforcement. The tiering text matches Anthropic's
guidance (code.claude.com/docs/en/costs, /best-practices, /sub-agents): Sonnet
for most coding, Haiku for simple subagent jobs, Opus by exception. The hooks
are headroom's own, and nothing shows yet that they pay for themselves.

### Measurement

- [ ] Add cost telemetry. 0.6 logs none. The pre-0.6 `report-warning.sh`
      wrote 89 `usage` records from 2026-10-04 to 2026-10-30; 82 had an
      empty model, zero tokens and `"transcript":"missing"`, so don't revive
      it as is. The Agent tool result carries `resolvedModel` but no usage;
      token counts arrive only as text in the completion notification. Use
      OpenTelemetry (docs: monitoring-usage): `claude_code.cost.usage` and
      `claude_code.token.usage` carry `model`, `query_source` (main,
      subagent, auxiliary), `agent.name` and `agent_id`, so cost per model
      and worker needs no hook and works for headless runs. Fallback:
      SubagentStop's `agent_transcript_path`, which fixes the old
      `"transcript":"missing"`. Old records aren't a baseline either: before
      2.1.293 `haiku` resolved to Haiku 4.5, which doesn't support effort.
- [ ] A/B against the native baseline: headroom disabled plus
      `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`, which is what headroom has to
      beat. The env var leaves Explore on the session model and every worker
      on the session effort, so the baseline also needs a custom `Explore`
      agent with `model: haiku`. Compare cost per session (`/usage`, or the
      OpenTelemetry metrics above) and task success on comparable work.
- [ ] Log whether each nudge was followed: an Agent spawn later in the same
      prompt, matched by the `prompt_id` in hook input. If fewer than about
      a third are followed, delete the nudges.

### Nudges (`plugins/headroom/hooks/budget.sh`)

- [ ] Remove the reading-budget nudge (`HEADROOM_READ_BUDGET`, 24576 bytes).
      It fires after the output is already in context, so it can only affect
      the rest of the prompt, and byte count can't tell output the
      orchestrator needed (docs lookups for an answer) from waste (a test log
      it only needed pass/fail from). It fired on exactly that false positive
      in a docs-research session. Claude Code already bounds the worst case:
      Bash output past 30,000 characters goes to a file with a
      2,000-character preview, and Read caps one call at 25k tokens and
      refuses whole files over 256 KB (docs: tools-reference).
- [ ] Don't build a PreToolUse hint for uncapped test, build or lint runs.
      PreToolUse `additionalContext` is "added to Claude's context alongside
      the tool result", so it lands after the command ran, like PostToolUse.
      Only a deny with a reason would prevent the output, and the native
      Bash cap already bounds it.
- [ ] Sweep detection: count distinct files read or searched in the current
      prompt, not bytes; past about 8-10, suggest `headroom:scout`. Not
      `Explore`: it runs on the session model and `CLAUDE_CODE_SUBAGENT_MODEL`
      doesn't change it (docs: sub-agents; ADR 0004). It does start without
      CLAUDE.md, so its startup is cheaper than a custom agent's.
- [ ] Don't bring back `read-guard.sh`; the native Read cap does its job. To
      tighten it, set `CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS`.
- [ ] Edit-budget nudge (`HEADROOM_EDIT_BUDGET`, 3 files):
  - [ ] Gate it on the session model: handing off pays only when the
        orchestrator costs much more than the worker. Never fire on a Sonnet
        session; fire on Opus or Fable. Only SessionStart receives `model`,
        and it can be missing after `/clear`, so `budget.sh` has to store it
        and update it on PostModelSwitch (`to_model`). No hook input carries
        effort, so the gate can't depend on it.
  - [ ] Fire on "a lot of work left", not "a lot of work done". Ideally,
        trigger on an approved plan with many steps (PostToolUse on
        `ExitPlanMode`, untested); failing that, raise the threshold to
        about 6. Three files is a routine single change (data, script, doc).

### Enforcement

- [ ] Check whether refusing spawns beats correcting them. A refusal costs a
      round trip and a retry. Alternatives:
  - [ ] `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` as the default: zero prompt
        tokens, explicit per-call models still win. It sets no effort.
  - [ ] A mod `agent.spawn` hook that sets the model (`next({ ...e, model })`)
        instead of refusing (docs: plugins/mods/reference#subagents). It
        doesn't re-run when a worker is resumed with SendMessage, and only
        `turn.step` documents changing effort.
  - [ ] PreToolUse `updatedInput` is documented but must pair with `allow`,
        which auto-approves every Agent call, or `ask`, and setting `model`
        through it is unconfirmed. Prefer `agent.spawn`.
- [ ] Keep refusing `fable` workers in `check-agent.sh`. Move the fork ban
      to settings: `CLAUDE_CODE_FORK_SUBAGENT=0` removes forks, so nothing
      gets refused and retried; a `permissions.deny` rule `Agent(fork)` also
      works. Both are user settings, so the README documents them instead
      of the hook enforcing the ban.
- [ ] Measure forks before keeping their ban. A fork reuses the parent's
      cached prefix, read at 0.05x base input on Opus 5.5 (docs:
      prompt-caching); a fresh Sonnet worker pays cache writes (1.25x) to
      re-read the same files. A fork's output bills at the session model's
      rate, so only read-heavy, output-light side tasks can come out ahead.
      Unverified, so it goes through the A/B, not the rules.
- [ ] `check-agent.sh` denies a call without `model` and `effort` even when
      the agent's frontmatter pins both (`headroom:scout` sets `haiku` and
      `medium`). The call parameter overrides frontmatter, so the hook
      makes agent definitions dead weight and costs a refusal whenever a
      call leans on them. Let the call through when the `subagent_type`'s
      agent file sets a concrete model and effort; keep denying `inherit`,
      no model and `fable`. Resolve the file in the documented precedence:
      managed, `--agents`, `.claude/agents`, `~/.claude/agents`, plugin
      `agents/` lowest; plugin agents are namespaced (`plugin:dir:name`).
      If that's too much shell, allowlist headroom's own agents first.
- [ ] Say in the README that `CLAUDE_CODE_EFFORT_LEVEL` beats both the
      call's `effort` and frontmatter. When it's set, headroom's effort
      tiering does nothing.

### Rules (`plugins/headroom/rules.md`)

- [ ] Cut rules.md from 793 words to about 250. It's injected at every
      start and compaction, and much of it changes no decision: what the
      hooks enforce (their denial messages already teach that), a restated
      Agent tool text on when to spawn and how to brief, and a Workflows
      section that mostly repeats the hook. Keep the tier table, the
      scout-vs-here routing, what every brief asks for, and the escalation
      ladder. The docs' "under 200 lines" is for CLAUDE.md and rules.md is
      already under it; the case is adherence and the re-injection cost.
- [ ] Add one sentence saying the tiers override the Agent tool's "set
      effort only when asked". Without it the orchestrator reconciles the
      contradiction itself every session.
- [ ] Scale the final Opus-high whole-branch review to the diff, like the
      other review rules. It's overkill for a one-line data change. Rough
      threshold: more than 5 files or about 200 changed lines, or a diff
      touching security or concurrency; otherwise Sonnet medium.
      `/code-review` levels set breadth, not model (docs:
      code-review-local), so the model choice is headroom's own.
- [ ] Spell out the trade-off between delegating and working here: a worker
      pays a fresh startup (system prompt, CLAUDE.md, tool schemas) that the
      orchestrator has already cached, so delegating a medium task can cost
      more than doing it in place. The docs confirm a non-fork worker
      doesn't read the parent's cache, loads CLAUDE.md (Explore and Plan
      excepted) and gets a 5-minute cache TTL (docs: prompt-caching).
- [ ] Say that an explicit level from the user (e.g. `/code-review high`)
      overrides the review tiering, not the other way round. `/code-review`
      reuses the last level the user typed.

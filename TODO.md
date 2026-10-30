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
      it as is. The Agent tool result already carries `resolvedModel` and
      `usage`, a better source than locating the worker transcript.
- [ ] A/B against the native baseline: headroom disabled plus
      `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`, which is what headroom has to
      beat. Compare cost per session (`/usage`) and task success on
      comparable work.
- [ ] Log whether each nudge was followed: an Agent spawn later in the same
      prompt. If fewer than about a third are followed, delete the nudges.

### Nudges (`plugins/headroom/hooks/budget.sh`)

- [ ] Remove the reading-budget nudge (`HEADROOM_READ_BUDGET`, 24576 bytes).
      It fires after the output is already in context, so it can only affect
      the rest of the prompt, and byte count can't tell output the
      orchestrator needed (docs lookups for an answer) from waste (a test log
      it only needed pass/fail from). It fired on exactly that false positive
      in a docs-research session.
- [ ] Replace it with predictive hints:
  - [ ] PreToolUse on Bash: hint when the command looks like a test suite,
        build or lint run (`pytest`, `go test ./...`, `cargo build`,
        `npm test`, ...) and nothing caps its output (`| tail`, `-q`, ...).
  - [ ] Sweep detection: count distinct files read or searched in the
        current prompt, not bytes; past about 8-10, suggest `Explore` or
        `headroom:scout`.
  - [ ] Bring back a size guard on individual Reads, like the old
        `read-guard.sh`, which prevents the cost instead of reporting it.
- [ ] Edit-budget nudge (`HEADROOM_EDIT_BUDGET`, 3 files):
  - [ ] Gate it on the session model: handing off pays only when the
        orchestrator costs much more than the worker. Never fire on a Sonnet
        session; fire on Opus or Fable at high effort.
  - [ ] Fire on "a lot of work left", not "a lot of work done". Ideally,
        trigger on an approved plan with many steps; failing that, raise the
        threshold to about 6. Three files is a routine single change (data,
        script, doc).

### Enforcement

- [ ] Check whether refusing spawns beats correcting them. A refusal costs a
      round trip and a retry. Alternatives:
  - [ ] `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` as the default: zero prompt
        tokens, explicit per-call models still win.
  - [ ] A mod `agent.spawn` hook that sets the model (`next({ ...e, model })`)
        instead of refusing (docs: plugins/mods/reference#subagents).
- [ ] Keep refusing what can't be fixed silently: `fable` workers and
      `subagent_type: "fork"`.
- [ ] Measure forks before keeping their ban. A fork reuses the parent's
      cached prefix, billed mostly as cache reads; a fresh Sonnet worker
      pays full input price to re-read the same files. For a
      context-heavy side task a fork may be cheaper even on Opus.
      Unverified, so it goes through the A/B, not the rules.
- [ ] `check-agent.sh` denies a call without `model` and `effort` even when
      the agent's frontmatter pins both (`headroom:scout` sets `haiku` and
      `medium`). The call parameter overrides frontmatter, so the hook
      makes agent definitions dead weight and costs a refusal whenever a
      call leans on them. Let the call through when the `subagent_type`'s
      agent file sets a concrete model and effort; keep denying `inherit`,
      no model, `fable` and `fork`. Resolving the file means searching
      plugin `agents/`, `~/.claude/agents` and `.claude/agents`; if that's
      too much shell, allowlist headroom's own agents first.
- [ ] Note the alias quirk in rules.md: when the session runs a model in the
      `opus` family, `model: opus` resolves to the session's exact model,
      not the alias target.

### Rules (`plugins/headroom/rules.md`)

- [ ] Cut rules.md from 793 words to about 250. It's injected at every
      start and compaction, and much of it changes no decision: what the
      hooks enforce (their denial messages already teach that), a restated
      Agent tool text on when to spawn and how to brief, and a Workflows
      section that mostly repeats the hook. Keep the tier table, the
      scout-vs-here routing, what every brief asks for, and the escalation
      ladder.
- [ ] Add one sentence saying the tiers override the Agent tool's "set
      effort only when asked". Without it the orchestrator reconciles the
      contradiction itself every session.
- [ ] Scale the final Opus-high whole-branch review to the diff, like the
      other review rules. It's overkill for a one-line data change. Rough
      threshold: more than 5 files or about 200 changed lines, or a diff
      touching security or concurrency; otherwise Sonnet medium.
- [ ] Spell out the trade-off between delegating and working here: a worker
      pays a fresh startup (system prompt, CLAUDE.md, tool schemas) that the
      orchestrator has already cached, so delegating a medium task can cost
      more than doing it in place.
- [ ] Say that an explicit level from the user (e.g. `/code-review high`)
      overrides the review tiering, not the other way round.

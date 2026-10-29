# Design: `consolidate-plans` skill

**Status:** Approved (design), pending implementation
**Date:** 2026-07-21
**Origin:** Distilled from a docs-consolidation run in one of my repositories, which consolidated 14 implemented plans + 5 implemented specs into a six-doc tree.

## Problem

Superpowers plans/specs accumulate in `docs/superpowers/` after execution. Executed plans are task lists with literal code — zero future value — and stale specs read as current truth. The backlog in that repository reached 14 plans (~450 KB) before cleanup. A reusable skill should make the cleanup repeatable in any repo that uses the superpowers plan/spec convention.

## Decisions (from brainstorm)

1. **Mode:** incremental + bootstrap. Primary use: fold recently implemented plans/specs into an existing docs tree. If no tree exists (or the backlog is large), the skill routes to the full ceremony instead of doing it inline.
2. **Location:** personal skill at `~/.claude/skills/consolidate-plans/SKILL.md` — available in all repos; repo specifics (topics, filenames) are discovered per run.
3. **Trigger:** user-invoked only; no lifecycle hook into finishing-a-development-branch. Mitigation for pile regrowth: every run starts with a cheap status report, so invoking it costs nothing when there is no work.
4. **Process weight:** lean, scaled by backlog. 1–3 pending plans run in-session with subagent fact-checkers; larger backlogs escalate to brainstorm → spec → plan → subagent-driven execution.

## The skill file

Single `SKILL.md`, no supporting files (workflow fits inline per writing-skills guidance).

**Frontmatter:**

```yaml
---
name: consolidate-plans
description: Use when asked to consolidate, clean up, or garbage-collect implemented superpowers plans/specs into project documentation, when asked which plans are implemented vs open, or when docs/superpowers/ has accumulated executed plans.
---
```

Description states triggering conditions only — never the workflow (writing-skills rule).

## Workflow (skill body)

### Phase 1 — Audit

- Inventory `docs/superpowers/plans/` and `docs/superpowers/specs/`.
- **Rule #1: checkbox state is unreliable.** Implementation status is determined ONLY by verifying artifacts in the code: files, scripts, dependencies, package.json entries, config the plan would have produced. (Evidence from that run: several fully shipped plans had zero boxes ticked; one partially ticked plan was fully shipped.)
- If findings contradict each other, re-check git state mid-run (branches can fast-forward under you — happened in the origin session).
- Output before touching anything: a status table — implemented / live (spec without code) / in-progress — reported to the user.

### Phase 2 — Route by backlog

- 0 pending → report the table and stop.
- 1–3 implemented-but-unconsolidated plans, docs tree exists → continue in-session (Phases 3–5).
- No docs tree yet, or a large backlog → recommend the full ceremony (brainstorm → spec → plan → subagent-driven execution) and stop. Do not attempt bootstrap-scale consolidation inline.

### Phase 3 — Consolidate

- Map each implemented plan/spec to affected topic docs; create new per-topic docs only when bootstrapping a missing topic.
- Distill **decisions and constraints**, not task lists or code snippets.
- **Rule #2: every factual claim is verified against current source, never copied from a plan/spec** — old documents predate later refactors (paths, names, behavior).
- Doc conventions (carried over from the docs tree of that run): 60–150 lines per doc; present tense; no history; `## Design notes` section for non-obvious constraints and their reasons; same-directory relative links between topic docs; entry-point pointers in README (linked list) and CLAUDE.md (one plain-text pointer line, architecture summary kept intact).

### Phase 4 — Independent fact-check (must not be skipped)

- One reviewer subagent per touched doc (Sonnet-tier per the headroom plugin), prompted to verify the doc's claims against named source files and report findings with file:line evidence.
- Fix Important findings and re-verify. (Origin-session evidence: this gate caught 3 real factual errors — an invented "silently breaks routing" claim, a wrong "both log streams" claim, and a misleading CORS-default bullet.)

### Phase 5 — Delete + verify

- Delete consolidated plans/specs in the same change-set; git history is the archive. Live specs and in-progress plans survive; list survivors explicitly.
- Gates: repo-wide grep proves nothing references deleted files; relative-link check over docs + README + CLAUDE.md resolves; project build/test/typecheck/lint still green.
- One branch; PR per repo convention (respect repo-specific tooling, e.g. bkt for Bitbucket).

## Validation (implementation-time, per writing-skills TDD)

- **RED:** baseline a subagent on "consolidate these plans" in a fixture repo without the skill; record failure modes (expected: trusts checkboxes, copies spec prose verbatim, deletes without reference check).
- **GREEN:** re-run with the skill loaded; verify it verifies artifacts, re-derives facts from source, and runs the Phase 5 gates.
- **REFACTOR:** plug any new rationalizations observed.

## Out of scope

- No hook into finishing-a-development-branch (explicit decision; revisit only if piles regrow annoyingly).
- No automation (cron/CI) — user-invoked.
- Not a general documentation-writing skill; it consolidates the superpowers plan/spec convention specifically.

## Open questions

None.

---
name: consolidate-plans
description: Use when asked to consolidate, clean up, or garbage-collect implemented superpowers plans/specs into project documentation, when asked which plans are implemented vs open, or when docs/superpowers/ has accumulated executed plans.
---

# Consolidate Plans

## Overview

Executed superpowers plans are task lists with literal code — zero future value once merged. Stale specs read as current truth and mislead. This skill folds the *durable* content of implemented plans/specs (decisions, constraints, rationale) into a concise current-state docs tree, then deletes the originals. Git history is the archive.

**Core principle:** documentation describes the system as it is, verified against source — never copied from the plan that built it.

## When to Use

- The user asks to consolidate/clean up implemented plans or specs
- The user asks which plans are implemented, in progress, or open
- `docs/superpowers/plans/` has accumulated executed plans

**When NOT to use:** mid-implementation (the plan is still the working document); repos that don't use the superpowers plan/spec convention.

## Phase 1 — Audit

Inventory `docs/superpowers/plans/` and `docs/superpowers/specs/`.

**RULE 1: Checkbox state is unreliable. Never determine implementation status from checkboxes.** Fully shipped plans routinely have zero boxes ticked; partially ticked plans may be fully shipped. Status is determined ONLY by verifying artifacts in the code: the files, scripts, dependencies, package.json entries, and config the plan would have produced.

- Cross-check specs against plans: a spec with no matching plan and no code artifacts is *live* (approved, unimplemented) — it survives consolidation.
- If two checks contradict each other, re-check git state (`git log --oneline -5`, `git status`) — branches can fast-forward mid-session while you work.

**Before touching anything**, report a status table to the user: implemented / live / in-progress, with the artifact evidence per row.

## Phase 2 — Route by backlog

| Finding | Action |
|---|---|
| 0 implemented-but-unconsolidated | Report the table. Stop. |
| 1–3 pending, docs tree exists | Continue with Phases 3–5 in-session. |
| No docs tree yet, or a large backlog | Recommend the full ceremony (brainstorming → spec → writing-plans → subagent-driven-development) and stop. Do NOT bootstrap a docs tree inline. |

## Phase 3 — Consolidate

Map each implemented plan/spec to the topic docs it affects. Distill **decisions and constraints**, never task lists or code snippets.

**RULE 2: Every factual claim is verified against current source before it is written. Never copy prose from a plan or spec** — they predate later refactors; their paths, names, and behavior claims are stale by construction.

Doc conventions:

- 60–150 lines per topic doc (`wc -l` check)
- Present tense, current-state only — no history, no "we changed X to Y"
- Each doc ends with `## Design notes`: short bullets, only non-obvious constraints and *why* they hold
- Same-directory relative links between topic docs
- Entry points: README gets/keeps a linked Documentation section; CLAUDE.md keeps its in-context summary intact and carries one plain-text pointer line to the tree (agents don't follow links — don't gut CLAUDE.md)
- While editing entry points, fix any claims the consolidated work made stale (tool names, versions)

## Phase 4 — Independent fact-check (never skip)

Dispatch one reviewer subagent per touched doc (Sonnet-tier; see the headroom plugin if installed). The reviewer verifies the doc's claims against named source files and reports findings with file:line evidence. Fix Important findings, re-verify.

This gate catches real errors: in the origin run it found an invented failure-mode claim, a wrong log-stream claim, and a misleading env-var-default claim — all plausible prose that contradicted source.

## Phase 5 — Delete + verify

- Delete consolidated plans/specs **in the same change-set** that updates the docs. Survivors: live specs, in-progress plans — list them explicitly in your report.
- Gates, all mandatory:
  1. Repo-wide grep proves nothing references a deleted file
  2. Every relative link in the docs tree + README + CLAUDE.md resolves
  3. Project build/test/typecheck/lint still green
- One branch; PR per the repo's convention (e.g. `bkt` on Bitbucket Server, `gh` on GitHub).

## Red Flags — STOP if you catch yourself thinking

| Thought | Reality |
|---|---|
| "The checkboxes say it's done/open" | Checkboxes lie. Verify artifacts in code. |
| "The spec describes this well, I'll reuse its wording" | Specs predate refactors. Re-derive every claim from source. |
| "It's just docs, no reviewer needed" | The fact-check gate caught 3 real errors in the origin run. |
| "I'll delete the plans first, then write docs" | Delete only in the same change-set as the docs that replace them. |
| "The backlog is huge but I can handle it inline" | Bootstrap-scale goes through the full ceremony. Stop and recommend it. |
| "I'll archive them to a folder instead" | An archive is a second, staler copy. Git history is the archive. |

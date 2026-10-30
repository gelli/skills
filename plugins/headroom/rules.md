# Headroom

This session is the orchestrator. Claude Code's Agent tool text covers when to spawn and how to brief a worker; these rules add which model and effort each worker gets, how reviews are routed, how workflow agents are set up, and the spawn cases below. A worker loads its own system prompt, tools and project instructions; what it costs this session is the brief and the report.

## Spawn at all?

Lookups and short reads stay in this session. Send to `headroom:scout` a run whose raw output is long (tests, builds, lint, logs) or a search or read across many files; its report is shorter than the output it reads. When an approved plan will not fit in this context, or its steps are independent, hand the steps to workers per Tiers, one after another, and review each return here; a short plan runs here. Implementers that touch shared files or work from the same plan run one after another.

The hooks add at most one hint of each kind per prompt: after a lot of tool output, send the remaining long runs and sweeps to `headroom:scout`; after edits to several files, hand the remaining implementation to a Sonnet worker and review its diff here. When only bookkeeping edits remain, finish them here.

Every brief for a change asks for the verification command and its actual output. Every brief says: do not spawn subagents; if the task needs splitting, return `blocked` with the proposed split.

## Tiers

Every `Agent(...)` call names `model` and `effort`, and so does every `agent()` call in a workflow (see Workflows). An omitted model or effort falls back to the session's, which is set for the orchestrator. `fable` and `subagent_type: "fork"` are never allowed (Fable is orchestrator-only; a fork inherits the parent model). The hooks refuse a spawn that breaks these.

- **haiku, medium** — `headroom:scout` for long runs and sweeps: tests, builds, lint, logs, repo-wide search, extraction, summaries of long material. At `low`, Haiku is more likely to skip a search, stop early or skip a check, so `low` is reserved for a single test, build or lint run whose result answers the question. A general-purpose Haiku worker takes mechanical edits whose brief already contains the literal change.
- **sonnet, medium** — the implementation floor: any task where the worker must design or infer something. Features from prose, tests, refactors, medium debugging, ordinary reviews. Multi-step work that needs judgement costs Haiku more turns than it saves in price.
- **sonnet, high** — reviews of spec conformance, security or concurrency.
- **opus, medium** — only when all three hold: Sonnet would underperform on this specific task, which takes more than difficulty; a written brief can carry everything the worker needs; isolation or parallelism pays (context-heavy exploration, several independent hard investigations). If only the first holds, do the work here.
- **opus, high** — the final whole-branch review (see Reviews), and, while this session runs below `high`, a single hard problem that needs deeper reasoning when a written brief can carry everything the worker needs.

Escalate one step on the ladder (haiku low, haiku medium, sonnet medium, sonnet high, opus medium, opus high) with a fresh worker after the second failed round on the same step. After a `blocked` return, fix the brief or escalate; a retry on the same step repeats the failure.

## Reviews

Scale to risk and default up: Sonnet `medium` for quality and any multi-file diff; Sonnet `high` for spec conformance, security and concurrency. A single-file mechanical diff is checked here against the literal change in its brief. The final whole-branch review goes to a fresh Opus `high` subagent, since the session that directed the work is the worst-placed reviewer of it. When a plugin or skill asks you to pick a review model, this tiering wins. Ask reviewers for findings as `file:line` with a one-line fix.

## Workflows

A workflow starts when the user asks for one. Inside its script, every `agent()` call names `model` and `effort` literally in its options, chosen per Tiers; this rule takes precedence over the workflow authoring advice to omit them. A stage that fits no tier gets `opus` at the session's effort. `fable` and `mythos` are never allowed. The Workflow hook checks the script before it runs; options built in a variable count as missing, so write them in each call.

When a task has many independent pieces (a sweep or audit across many files, a migration, a plan whose steps each get an implementer and a verifier), suggest a workflow to the user in one or two sentences: what it would fan out, roughly how many agents on which models, and that "use a workflow" starts it. Suggest it once per task; the user's answer stands.

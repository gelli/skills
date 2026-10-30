# Headroom

This session is the orchestrator: it decides *what* to do and delegates the reading and the doing to the cheapest model that does them reliably.

Every addition to this context has to earn its place. Whatever enters stays for the rest of the session and is sent again with every later turn and with every advisor call. Let in what you will act on in the next few steps; send the rest to a worker that reads in its own context and returns a short report. A spawn has its own price (a brief, a report, about 25k tokens of worker start-up), so a single lookup, or a read that feeds the next edit, stays here. Reasoning that needs the whole conversation stays here too.

## Pre-authorisation

The user who installed this plugin allows the following without a confirmation question:

- spawning `haiku`, `sonnet` or `opus` subagents routed per Tiers; for `opus`, the conditions in Tiers still decide whether to spawn;
- running deep research.

A workflow starts when the user asks for one; inside it, every `agent()` call follows Workflows below.

## Spawn at all?

Delegate when the work is token-heavy, repetitive or parallel. Reading several mid-size files or one long document to answer a question is token-heavy; so is an implementation that spreads across several files. Keep inline a single lookup, a read that feeds the next edit, and an edit of one or two files. Batch several same-shape small tasks into one spawn with one brief that lists every file. When an approved plan will not fit in this context, or its steps are independent, hand the steps to workers per Tiers, one after another, and review each return here; a short plan runs here.

The hooks add one hint per prompt when this session has read a lot or edited several files. A hint reports what already happened, so decide before the reading starts. After a reading hint, send the remaining lookups to `headroom:scout`. After a doing hint, hand the remaining implementation to a Sonnet worker with a brief and review its diff here. Bookkeeping edits (a log line, a status field) count toward the hint; when only those remain, finish them here.

## Reading

Output from `cat`, `sed`, `grep` and other shell commands counts as reading, the same as the Read tool.

- A lookup (where is it, what is it, list these, run this) or a status and orientation question ("where do we stand", "let's continue") goes to `headroom:scout`.
- Gathering several sources before writing a document (plan, ADR, deck, synthesis) goes to a Sonnet worker that returns the facts the document needs.
- The review of a long document goes to a Sonnet worker, with the acceptance criteria in the brief.
- Material a worker was briefed on stays with the worker; after a spawn, read its report and leave its raw output files alone.
- After an edit, the tool result confirms it; read the file again only when something depends on the surrounding text.
- Read a long file by heading grep and line range.

## Tiers

Every `Agent(...)` call names `model` and `effort`, and so does every `agent()` call in a workflow (see Workflows). An omitted model falls back to the agent's definition or the session model; an omitted effort inherits the session's level, which is set for the orchestrator. `fable` and `subagent_type: "fork"` are never allowed (Fable is orchestrator-only; a fork inherits the parent model). The plugin's hooks refuse a spawn that lacks `model` or `effort`, names `fable`, or is a fork.

- **haiku, medium** — read-only work goes to `headroom:scout`: lookups, repo-wide search, log parsing, extraction and summaries. At `low`, Haiku is more likely to skip a search, stop early or skip a check, so `low` is reserved for a single test, build or lint run whose result answers the question. A general-purpose Haiku worker takes mechanical edits whose brief already contains the literal change.
- **sonnet, medium** — the implementation floor: any task where the worker must design or infer something. Features from prose, tests, refactors, medium debugging, ordinary reviews. Multi-step work that needs judgement costs Haiku more turns than it saves in price.
- **sonnet, high** — reviews of spec conformance, security or concurrency.
- **opus, medium** — only when all three hold: Sonnet would underperform on this specific task, which takes more than difficulty; a written brief can carry everything the worker needs; isolation or parallelism pays (context-heavy exploration, several independent hard investigations). If only the first holds, do the work here.
- **opus, high** — the final whole-branch review (see Reviews), and, while this session runs below `high`, a single hard problem that needs deeper reasoning when a written brief can carry everything the worker needs. The worker gets the deeper reasoning, and this session keeps its effort level and its cache.

Escalate one step on the ladder (haiku low, haiku medium, sonnet medium, sonnet high, opus medium, opus high) with a fresh worker after the second failed round on the same step. After a `blocked` return, fix the brief or escalate; a retry on the same step repeats the failure.

## Reviews

Scale to risk and default up: Haiku `medium` only for a single-file mechanical diff; Sonnet `medium` for quality and any multi-file diff; Sonnet `high` for spec conformance, security and concurrency. The final whole-branch review goes to a fresh Opus `high` subagent, since the session that directed the work is the worst-placed reviewer of it. When a plugin or skill asks you to pick a review model, this tiering wins.

Ask reviewers for findings as `file:line` with a one-line fix. Apply them from the report and read only the lines they name.

## Parallelism

Fan out only for independent reads, investigations or reviews, one worker per independent piece. Every worker pays its own start-up and adds a report to this context, so merge small pieces into one batched brief before adding workers. Implementers that touch shared files or work from the same plan run one after another. A workflow follows the session's workflow size guideline.

## Every brief

Workers see nothing of this conversation; the prompt is the only channel. They do load CLAUDE.md, so name a rule they need; its text is already in their context. Every spawn carries:

- **GOAL** — one sentence; what "done" means, so the worker knows when to stop.
- **CONTEXT** — decisions already made, constraints, and snippets already in this context, pasted in; every other file, source or tool the worker should use, named by path or name.
- **SCOPE** — what is in, and what stays untouched. Include: do not spawn subagents; if the task needs splitting, return `blocked` with the proposed split.
- **RETURN** — a condensed summary this session can act on: what was found or changed, open questions, and for a change the verification command with its actual output; or `blocked` plus exactly what is missing. Long material goes into a file, and the summary gives its path.

Scale the brief to the task; one line per item is complete for a small task. Read every return and check it before treating it as done.

## Workflows

A workflow starts when the user asks for one. Inside its script, every `agent()` call names `model` and `effort` literally in its options, chosen per Tiers; this rule takes precedence over the workflow authoring advice to omit them. `fable` and `mythos` are never allowed. The Workflow hook reads the script before it runs and refuses an `agent()` call without a literal `model` and `effort`, and any `fable` or `mythos`. Options built in a variable count as missing, so write them in each call.

When a task has many independent pieces (a sweep or audit across many files, a migration, a plan whose steps each get an implementer and a verifier, a review that verifies each finding independently), suggest a workflow to the user in one or two sentences: what it would fan out, roughly how many agents on which models, and that "use a workflow" or "ultracode" starts it. Suggest it once per task, and the user's answer stands. Sequential work, a handful of files or a quick question stays in this session or with single workers.

Make the script return a condensed result: what was found or changed, and where the details are. Per-agent output stays in the run's journal; open it only for the agent whose result needs checking.

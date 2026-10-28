---
name: deepen
description: Rewrite a task prompt into a deeper version at the same scope, held to the standard a top practitioner of the field would apply. Use when the user invokes /deepen, asks to deepen, sharpen or raise the bar on a prompt or task, or asks what an expert would do differently before starting.
argument-hint: <the prompt or task to deepen>
---

# Deepen a prompt

Deepen this task: $ARGUMENTS

Deeper means the same scope held to a higher standard: closer to the primary evidence, sharper methods, and a check that something outside this conversation can pass or fail. A bigger task with more sections or more sources is a different request; push back if that is what the rewrite drifts towards.

If the argument is empty, take the task from the conversation so far. If none is clear, ask for it in one line.

## 1. Name the practitioner

Name the concrete role that would own this task professionally (forensic code auditor, clinical safety officer, data reconciliation analyst, structural engineer). A generic "expert" is a failure of this step. Every answer below must be one that this role would give and a different role would not.

## 2. Answer four questions

Answer each in bullets, as many as the task needs.

1. **What they would do that the prompt does not ask for.** The professional habits the request skips: framing, scoping, the question they would ask before starting.
2. **The rawest material they would start from.** The primary sources: records, data, code, logs, transcripts, the system itself. Name where each lives and mark it **reachable** only after opening or listing it from this session (repo, database, notes folder, an MCP server); everything else is a **gap**, with who or what holds it. Prefer a reachable source over an ideal one that nobody can open.
3. **Methods and tools.** Each with one line on what it catches that the current approach would miss. Drop any entry without such a line. When a tool's current behaviour matters, look it up (context7, the tool's docs) before naming flags or APIs.
4. **What shows the result is right, other than the model or the user.** A test that can fail, a reconciliation against a source of record, a named person with standing to judge, or a prediction written down before the work starts. State the pass condition concretely; this becomes the acceptance criterion of the rewrite. The check costs a small fraction of the task itself; a check that needs its own deliverable or project is scope drift.

Before moving on, reread every bullet and delete any that would fit a different task unchanged.

## 3. Decide whether depth pays

State the added cost of the deeper version in plain terms (hours, access to request, people to involve). If the original prompt already meets the practitioner's standard, or the cost outweighs what the task is for, say so and stop without a rewrite. That is a valid outcome.

## 4. Rewrite the prompt

Write the rewritten prompt in a fenced block, ready to paste. It names the practitioner's standard, the raw sources to start from (with the gaps as explicit asks), the methods, and the acceptance criterion from question 4 as the definition of done. Keep the original goal and scope word for word where they still hold.

Then ask whether to run it. Do not run it unasked.

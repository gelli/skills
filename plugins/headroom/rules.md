# headroom

The main context is the scarce resource here: it holds the whole conversation, and every advisor call re-bills its tokens. Push token-heavy work into workers so only their reports enter it.

**Delegate when:** repo-wide search or code whose location is unknown; test/build/lint/type-check runs; log analysis; reading more than about 3 files, or any file over about 500 lines, to answer a question; web or docs research; reviewing a multi-file change; writing code that spans several files, follows a plan, or needs a test-fix loop.

**Stay inline for:** a single lookup; reading one file you already know; a one-file edit; a change whose design is still being settled in this conversation. After an inline edit, send a scout to run the tests.

**Roles:** `headroom:scout` (haiku), `headroom:implementer` (sonnet, high effort), `headroom:reviewer` (sonnet, high effort). Pass `model` only to raise: scout to sonnet for multi-step research; implementer or reviewer to opus for escalation, the final whole-branch review, or a hard investigation. Never lower, never fable, never inherit, never fork. `general-purpose` and untyped spawns need an explicit model; other named agent types keep their own.

**Brief every spawn:** GOAL / CONTEXT (paste it, including the scratch-directory path for report files) / SCOPE (state "do not spawn subagents") / RETURN. Workers see nothing of this conversation.

**Reports:** at most 40 lines; longer material goes into a report file, read only if you need it.

**Escalation:** after a failed review, the same implementer gets two rounds to fix it, then a fresh implementer raised to opus, then stop and decide with the user.

**Parallelism:** independent reads or reviews may run in parallel, up to five. Never run two implementers in parallel on shared files.

**Pre-authorisation:** the user who installed headroom authorises spawning the three roles without asking. Workflows run only when the user asks for one; inside a workflow every agent names a model, never fable.

**Elsewhere:** questions outside this codebase, such as a library choice or comparing approaches, are better served by `/deep-research` than by a worker; suggest it to the user rather than running it yourself. If blocks are enabled, they refuse test/build runs and repo-wide searches here; delegate to headroom:scout, or ask the user to run `/headroom:inline` (this call only) or `/headroom:inline session` — that skill is user-invocable only, so you cannot run it yourself.

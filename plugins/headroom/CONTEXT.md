# headroom

Keeps the orchestrator's context small and sharp by moving token-heavy work into workers. Choosing the model and effort a worker runs on comes second; cost is a tiebreaker.

## Language

### Sessions and workers

**Orchestrator**:
The main session the user talks to; it holds the decisions and the whole conversation.
_Avoid_: main agent, parent, main thread

**Main context**:
The orchestrator's context window, the resource this plugin protects.
_Avoid_: session memory, history

**Worker**:
A subagent the orchestrator spawns with a written brief; it sees nothing but the brief.
_Avoid_: child, helper, fork

**Delegation**:
Handing a task to a worker so that its intermediate output never enters the main context.
_Avoid_: offloading, outsourcing

**Brief**:
The prompt the orchestrator writes for a worker; the worker's only source of context.
_Avoid_: task description, instructions

**Spec**:
The durable statement of what a change must do; kept in a file when the work spans more than one worker, so the brief points to it instead of restating it.
_Avoid_: requirements doc, PRD

**Report**:
The short final message a worker returns to the orchestrator; the only part of its work that enters the main context.
_Avoid_: result, output, return value

**Report file**:
A scratch file where a worker puts anything too long for its report; the report names the path.
_Avoid_: dump, log file

### Roles

**Role**:
A worker type shipped by the plugin, fixed by its tool set and instructions, with a default model that a spawn may only raise.
_Avoid_: agent type, persona, tier

**Scout**:
The role for single-shape jobs: search, logs, test and build runs, doc lookups. The ban on Edit and Write is enforced; beyond that, "changes no project files" depends on instructions, since it also has Bash and MCP tools.
_Avoid_: explorer, researcher

**Implementer**:
The role that writes code from a brief and runs its own tests.
_Avoid_: executor, coder, builder

**Reviewer**:
The role that judges work against its spec and for quality, from the code rather than the implementer's report. The ban on Edit and Write is enforced; beyond that, "changes no project files" depends on instructions, since it also has Bash.
_Avoid_: verifier, auditor, checker

**Escalation**:
Re-running a failed task on a fresh worker with a raised model, after the same worker's retries are spent.
_Avoid_: retry, upgrade

### Enforcement

**Block**:
A refusal of a delegable tool call made by the orchestrator, including a whole-file Read of a large file (on by default); workers are never blocked.
_Avoid_: deny, guard

**Nudge**:
A reminder injected into the main context after the orchestrator took in a large tool output.
_Avoid_: warning, hint

**Inline override**:
A user-granted, one-call or session-scoped lift of blocks, including the large-file Read refusal.
_Avoid_: bypass, escape hatch

**Advisor**:
A stronger reviewer model that reads the orchestrator's full transcript on demand; not a worker.
_Avoid_: reviewer subagent

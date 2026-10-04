# headroom:scout, not Explore, for search and lookup work

> Status: the model-less `Explore`/`Plan` denial listed below as a considered option was adopted in 0.3.0 (see docs/plans/2026-10-04-headroom-0.3.md), superseding its rejection here. The reasoning below is the original 0.2 record.

rules.md tells the orchestrator to prefer `headroom:scout` over the built-in `Explore` subagent for search, lookup and doc work. Explore inherits the main session's model, capped at Opus, so on an Opus orchestrator every Explore spawn runs on Opus regardless of the job's size. Scout defaults to haiku, keeps Bash for test and build runs, and follows the same 40-line report-file rule as headroom's other roles. check-agent.sh still runs an `Explore` or `Plan` spawn through the fork, fable/mythos and inherit denials that apply to every subagent_type; only the role/model-rank check that ranks scout, implementer and reviewer's models does not apply to them.

## Considered Options

- **Deny an `Explore` or `Plan` spawn that omits a model, the way `general-purpose` is denied.** Would force every Explore spawn onto an explicit tier immediately, but it interrupts Claude Code's own automatic Explore spawns, and no log yet shows how often Explore actually runs on Opus in practice.
- **Leave Explore unmentioned in rules.md and let the orchestrator reach for it as usual.** Costs nothing to write, but gives up the one place headroom can cheaply steer the orchestrator toward a role with a known, cheaper default model.

## Consequences

- rules.md carries one line steering the orchestrator toward scout; nothing stops a direct Explore call, so cost still depends on the orchestrator following the rule.
- The trigger is report-warning.sh's SubagentStop usage line, not check-agent.sh's allow log: check-agent.sh logs `model` as passed on the Agent call, which is empty for a default Explore spawn, so it can never show Explore running on Opus. report-warning.sh's usage line records the model Explore actually ran on, read from its own transcript. Once that line shows Explore running on Opus in practice, plan item 4.7 in docs/plans/2026-09-27-headroom-0.2.md adds the denial.

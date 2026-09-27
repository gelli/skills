# A role's model is a default that a spawn may only raise

Each role (scout, implementer, reviewer) is fixed by its tool set and instructions, not by its model. The agent file sets a default model, and a spawn may pass a higher one but never a lower one, and never Fable. We chose this over one role per model because every framework we surveyed (superpowers, GSD, whose main repository was archived in mid-2026 after this survey) picks the model per task, not per role, and because escalation after a failed review needs the same role on a stronger model. Adding roles per model would have grown the Agent tool listing, and a longer listing makes the orchestrator less likely to delegate at all.

## Considered Options

- **Model fixed to the role, per-spawn `model` rejected.** Predictable, but a one-line fix pays for an Opus review, and escalation needs a second implementer role.
- **Model free per spawn, in both directions.** Flexible, but a spawn can quietly downgrade a reviewer to Haiku and undo the reason the role exists.

## Consequences

- The scout's file carries no effort level because Haiku supports none, so a scout raised to Sonnet runs at the session's effort.
- The spawn check must rank model IDs, full IDs as well as aliases, to tell raising from lowering.

---
name: inline
description: "Lift headroom's block for the next blocked call, or with 'session' for the rest of the session."
argument-hint: "[session]"
disable-model-invocation: true
---

The hook has already recorded the lift before this skill runs. Confirm in one line which scope applies: "once" (the next blocked call only) if `$ARGUMENTS` is empty, or "for the rest of the session" if `$ARGUMENTS` is `session`. Then retry the call that was just refused, if there was one.

# deepen

Rewrites a task prompt into a deeper version at the same scope, held to the standard a top practitioner of the field would apply. It names that practitioner's role, then asks what they would do that the prompt skips, which primary sources they would start from (and which of those this session can actually reach), which methods catch what the current approach misses, and what check outside the conversation shows the result is right. If depth does not pay for the task, it says so and stops. Otherwise it writes the rewritten prompt, ready to paste, and asks before running it.

Use it before starting a task, to see what an expert would do differently.

## Install

```
/plugin marketplace add gelli/skills
/plugin install deepen@gelli-skills
```

Invoke it as `/deepen:deepen <prompt or task>`.

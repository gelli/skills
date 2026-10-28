# consolidate-plans

Cleans up the plans and specs that the superpowers workflow leaves in `docs/superpowers/`. Executed plans are task lists with literal code and no future value, and stale specs read as current truth. The skill checks each plan against the code (never against its checkboxes), folds what is implemented into the project documentation, deletes the executed plans, and reports which plans are still open.

The reasoning behind the skill's rules is in [docs/DESIGN.md](docs/DESIGN.md).

## Install

```
/plugin marketplace add gelli/skills
/plugin install consolidate-plans@gelli-skills
```

Invoke it as `/consolidate-plans:consolidate-plans`, or ask Claude which plans are implemented.

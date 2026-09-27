# Headroom roles are workers, not agent-teams teammates

check-agent.sh denies a `headroom:scout`, `headroom:implementer` or `headroom:reviewer` spawn that carries `name`: `name` is what turns a plain worker spawn into an agent-teams teammate. Agent teams are experimental and off by default, and while a teammate is documented to honour a definition's `tools` and `model`, `disallowedTools` is not documented as applying to it. Scout's write ban rests on `disallowedTools` alone, so a teammate that dropped it would gain Edit and Write outright; reviewer keeps a `tools` allowlist as well, so the same gap would matter less for it. Phase 0 found the restriction held for a headless `headroom:reviewer` spawned with `name`, which still had no Write tool, but agent teams did not fully engage in that headless run, so a real interactive teammate remains untested.

## Considered Options

- **Allow `name` and rely on `disallowedTools` holding for teammates too.** Costs nothing extra, but rests on behaviour the docs don't state and Phase 0 could only confirm headlessly; a false confirmation would hand scout, whose ban has no allowlist backing it, Edit and Write.
- **Gate teammates on the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` environment variable instead.** Would only restrict roles when teams are enabled, but a spawn check has no reason to read an env var when denying `name` on headroom roles works the same regardless of the flag.

## Consequences

- A user who wants a scout, implementer or reviewer as an agent-teams teammate copies the agent file rather than passing `name` to the shipped role.
- Revisit if a real interactive teammate run confirms `disallowedTools` holds, or if agent teams leave experimental status.

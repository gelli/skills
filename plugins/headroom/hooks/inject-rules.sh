#!/bin/sh
# headroom SessionStart hook: put the headroom rules into context on
# startup, clear and after compaction (not resume: the transcript already
# holds them). Plain stdout is added to Claude's context verbatim.
# Reads nothing from stdin, writes nothing.
set -u
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
rules="$root/rules.md"
[ -r "$rules" ] || exit 0
printf '<headroom>\nRules for every Agent(...) spawn and Workflow run in this session. The plugin hooks enforce the mechanical part. The Agent check refuses a spawn without an explicit model or a valid effort, model fable and subagent_type fork. The Workflow check refuses a script that requests fable or mythos as an agent model and a script with an agent() call whose options lack a literal model or effort; two nudges fire once per prompt, one past a reading budget and one past a third edited file. The judgment calls are yours.\n\n'
cat "$rules"
printf '\n</headroom>\n'

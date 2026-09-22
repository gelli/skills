#!/bin/sh
# model-routing SessionStart hook: put the routing rules into context on
# startup, clear and after compaction (not resume: the transcript already
# holds them). Plain stdout is added to Claude's context verbatim.
# Reads nothing from stdin, writes nothing.
set -u
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
rules="$root/routing.md"
[ -r "$rules" ] || exit 0
printf '<model-routing>\nRules for every Agent(...) spawn in this session. The plugin hook enforces the mechanical part (explicit model, no fable, no fork); the judgment calls are yours.\n\n'
cat "$rules"
printf '\n</model-routing>\n'

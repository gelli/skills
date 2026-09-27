#!/bin/sh
# headroom SessionStart hook: puts rules.md into context on startup, clear
# and after compaction (not resume: the transcript already holds it). Plain
# stdout is added to Claude's context verbatim. Reads nothing from stdin,
# writes nothing. A missing or unreadable rules.md prints nothing.
set -u
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
rules="$root/rules.md"
[ -r "$rules" ] || exit 0
printf '<headroom>\n'
cat "$rules"
printf '\n</headroom>\n'

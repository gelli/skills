#!/bin/sh
# headroom PreToolUse hook for the Workflow tool: denies a workflow whose
# script (inline tool_input.script, or read from tool_input.scriptPath) asks
# for fable or mythos as an agent model. A named workflow with no script text
# to inspect is allowed, and nothing else is ever blocked.
#
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it allows silently and notes the gap on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.tool_input.scriptPath // ""),
  (.tool_input.script // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
t = d.get("tool_input") or {}
print("parsed")
print(t.get("scriptPath") or "")
print(t.get("script") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); Workflow check skipped" >&2
  exit 0
fi

# script can be multi-line, so it is always the last field extracted;
# scriptPath is a plain single-line path.
script_path=$(printf '%s\n' "$fields" | sed -n 2p)
script=$(printf '%s\n' "$fields" | sed -n '3,$p')

content="$script"
if [ -z "$content" ] && [ -n "$script_path" ] && [ -r "$script_path" ]; then
  content=$(cat "$script_path" 2>/dev/null || true)
fi

# Named workflow (tool_input.name only) or no script text to inspect: allow.
[ -n "$content" ] || exit 0

sq="'"
dq='"'
bt='`'
quote_class="[${sq}${dq}${bt}]"
not_quote_class="[^${sq}${dq}${bt}]"
fable_pattern="model[[:space:]]*:[[:space:]]*${quote_class}${not_quote_class}*(fable|mythos)"

# grep matches per line, so a key and value split across lines (e.g.
# "model:\n  \"fable\"") would otherwise pass; flatten newlines to spaces
# first, for both the inline script and a script read from scriptPath.
flat_content=$(printf '%s' "$content" | tr '\n' ' ')

if printf '%s' "$flat_content" | grep -Eiq "$fable_pattern"; then
  hr_log deny check-workflow "workflow script requests fable/mythos as a model"
  hr_deny "headroom: this workflow's script requests \"fable\" or \"mythos\" as an agent model. Fable and Mythos are orchestrator/advisor-only; set that model to haiku, sonnet, or opus."
  exit 0
fi

exit 0

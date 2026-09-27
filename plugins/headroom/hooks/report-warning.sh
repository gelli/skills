#!/bin/sh
# headroom SubagentStop hook: talks to the WORKER, not the main session. When
# a worker's own final report is long enough to defeat the point of
# delegating (only the report, not the worker's intermediate output, was
# ever meant to enter the main context), this blocks the worker from
# stopping and asks it to resend a shorter report with a report file.
# Thresholds: 60 lines, 8000 bytes.
#
# SubagentStop's additionalContext and decision:"block" both go to the
# SUBAGENT, never the parent session (a PostToolUse hook on Agent would be
# needed to reach the parent). Skips silently when agent_type is empty
# (Claude Code's own internal agents, e.g. prompt suggestions, not a
# headroom worker) or when stop_hook_active is true (already looping once;
# do not loop forever). If a background worker delivered its report through
# a hand-back (SubagentHandback), this hook only ever sees the worker's
# closing text in last_assistant_message, not the delivered report, and so
# does nothing about the report's real length.
#
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it does nothing and notes the gap on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

LINE_LIMIT=60
BYTE_LIMIT=8000

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.agent_type // ""),
  (if .stop_hook_active then "true" else "false" end),
  (.last_assistant_message // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("parsed")
print(d.get("agent_type") or "")
print("true" if d.get("stop_hook_active") else "false")
print(d.get("last_assistant_message") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); report-warning check skipped" >&2
  exit 0
fi

agent_type=$(printf '%s\n' "$fields" | sed -n 2p)
stop_hook_active=$(printf '%s\n' "$fields" | sed -n 3p)
message=$(printf '%s\n' "$fields" | sed -n '4,$p')

# Not a headroom worker, or already looping once: do nothing.
[ -n "$agent_type" ] || exit 0
[ "$stop_hook_active" != true ] || exit 0

lines=$(printf '%s\n' "$message" | wc -l | tr -d '[:space:]')
bytes=$(printf '%s' "$message" | wc -c | tr -d '[:space:]')

if [ "$lines" -le "$LINE_LIMIT" ] && [ "$bytes" -le "$BYTE_LIMIT" ]; then
  exit 0
fi

# ~4 bytes per token.
kt=$((bytes / 4096))
[ "$kt" -gt 0 ] || kt=1
hr_log report report-warning "$agent_type report was $lines lines / $bytes bytes"
hr_block "headroom: your report is $lines lines (~${kt}k tokens). Move the detail into a report file in the scratch directory named in your brief and resend a report of at most 40 lines that gives its path."

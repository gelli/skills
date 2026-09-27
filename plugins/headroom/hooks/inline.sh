#!/bin/sh
# headroom UserPromptSubmit hook: /headroom:inline lifts block.sh's block for
# the next blocked call ("once"), or for the rest of the session ("session").
# Writes the scope to $CLAUDE_PLUGIN_DATA/inline/<session_id>; block.sh reads
# it and, for "once", deletes it after use. Any other prompt is a no-op.
#
# UserPromptSubmit fires with the raw submitted text before slash-command
# expansion, so this matches the literal "/headroom:inline" prefix rather
# than an expanded skill invocation.
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it does nothing and notes the gap on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.session_id // ""),
  (.prompt // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("parsed")
print(d.get("session_id") or "")
print(d.get("prompt") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); inline override skipped" >&2
  exit 0
fi

session_id=$(printf '%s\n' "$fields" | sed -n 2p)
prompt=$(printf '%s\n' "$fields" | sed -n '3,$p')
trimmed=$(printf '%s' "$prompt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

case "$trimmed" in
  "/headroom:inline")
    scope=once
    ;;
  "/headroom:inline "*)
    rest=${trimmed#/headroom:inline }
    rest=$(printf '%s' "$rest" | sed -e 's/^[[:space:]]*//')
    case "$rest" in
      session*) scope=session ;;
      *) scope=once ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac

[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || exit 0
[ -n "$session_id" ] || exit 0
mkdir -p "$CLAUDE_PLUGIN_DATA/inline" 2>/dev/null || exit 0
printf '%s' "$scope" >"$CLAUDE_PLUGIN_DATA/inline/$session_id" 2>/dev/null || exit 0
hr_log override inline "wrote $scope override for session $session_id"
exit 0

#!/bin/sh
# headroom PostToolUse hook for Read|Bash|Grep|Glob|WebFetch: in the main
# session only (never for a worker's own tool calls), nudges once a tool
# response is large enough that reading it in place is worth delegating to
# headroom:scout next time.
#
# Size is the byte length of tool_response, compactly re-serialised as JSON
# (jq's tojson, or Python's json.dumps with no extra whitespace and
# ensure_ascii=False, written as raw UTF-8 bytes, so the two parser paths
# agree closely -- jq's tojson does not \u-escape non-ASCII either).
# Threshold: 32768 bytes (~8k tokens).
#
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it does nothing and notes the gap on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

THRESHOLD=32768

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.agent_id // ""),
  (.tool_name // ""),
  (.tool_response | tojson)
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("parsed")
print(d.get("agent_id") or "")
print(d.get("tool_name") or "")
sys.stdout.flush()
serialised = json.dumps(d.get("tool_response"), separators=(",", ":"), ensure_ascii=False)
sys.stdout.buffer.write(serialised.encode("utf-8"))
sys.stdout.buffer.write(b"\n")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); nudge check skipped" >&2
  exit 0
fi

agent_id=$(printf '%s\n' "$fields" | sed -n 2p)
tool_name=$(printf '%s\n' "$fields" | sed -n 3p)
serialised=$(printf '%s\n' "$fields" | sed -n 4p)

# Worker tool calls are never nudged, only the main session's own.
[ -z "$agent_id" ] || exit 0

size=$(printf '%s' "$serialised" | wc -c | tr -d '[:space:]')
[ "$size" -gt "$THRESHOLD" ] || exit 0

# ~4 bytes per token (32768 bytes ~ 8k tokens).
kt=$((size / 4096))
[ "$kt" -gt 0 ] || kt=1
hr_log nudge nudge "$tool_name response was $size bytes (~${kt}k tokens)"
hr_add_context PostToolUse "headroom: that $tool_name output was about ${kt}k tokens in the main context. Next time send this kind of work to headroom:scout."

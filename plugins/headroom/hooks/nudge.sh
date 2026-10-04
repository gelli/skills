#!/bin/sh
# headroom PostToolUse hook for Read|Bash|Grep|Glob|WebFetch|WebSearch|
# mcp__.*: in the main session only (never for a worker's own tool calls),
# nudges once a tool response is large enough that reading it in place is
# worth delegating to headroom:scout next time.
#
# Size measures what the model actually took in, not the raw tool_response
# (found by Phase 0 check C3, plan 1.9):
# - Bash: tool_response.stdout is capped at exactly 30,000 characters, and
#   once output is persisted the model sees only a ~2KB preview plus a
#   persistedOutputPath -- the full stdout never enters the main context, so
#   a persistedOutputPath present means no nudge. Otherwise the byte length
#   of stdout + stderr.
# - Read: the byte length of tool_response.file.content.
# - Everything else (Grep, Glob, WebFetch, WebSearch, mcp__.*): the byte
#   length of tool_response, compactly re-serialised as JSON (jq's tojson,
#   or Python's json.dumps with no extra whitespace and ensure_ascii=False,
#   written as raw UTF-8 bytes, so the two parser paths agree closely --
#   jq's tojson does not \u-escape non-ASCII either).
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
  (if (.tool_name // "") == "Bash" and (.tool_response.persistedOutputPath // null) != null then "skip" else "" end),
  (
    if (.tool_name // "") == "Bash" then
      (.tool_response.stdout // "") + (.tool_response.stderr // "")
    elif (.tool_name // "") == "Read" then
      (.tool_response.file.content // "")
    else
      (.tool_response | tojson)
    end
  )
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tool_name = d.get("tool_name") or ""
tr = d.get("tool_response")
if not isinstance(tr, dict):
    tr = {}
if tool_name == "Bash":
    skip = "skip" if tr.get("persistedOutputPath") is not None else ""
    measured = (tr.get("stdout") or "") + (tr.get("stderr") or "")
elif tool_name == "Read":
    skip = ""
    file = tr.get("file")
    measured = (file or {}).get("content") or ""
else:
    skip = ""
    measured = json.dumps(d.get("tool_response"), separators=(",", ":"), ensure_ascii=False)
print("parsed")
print(d.get("agent_id") or "")
print(tool_name)
print(skip)
sys.stdout.flush()
sys.stdout.buffer.write(measured.encode("utf-8"))
sys.stdout.buffer.write(b"\n")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); nudge check skipped" >&2
  exit 0
fi

agent_id=$(printf '%s\n' "$fields" | sed -n 2p)
tool_name=$(printf '%s\n' "$fields" | sed -n 3p)
skip=$(printf '%s\n' "$fields" | sed -n 4p)
measured=$(printf '%s\n' "$fields" | sed -n '5,$p')

# Worker tool calls are never nudged, only the main session's own.
[ -z "$agent_id" ] || exit 0
# Bash output that was persisted: the model only saw a ~2KB preview.
[ "$skip" != skip ] || exit 0

size=$(printf '%s' "$measured" | wc -c | tr -d '[:space:]')
[ "$size" -gt "$THRESHOLD" ] || exit 0

# ~4 bytes per token (32768 bytes ~ 8k tokens).
kt=$((size / 4096))
[ "$kt" -gt 0 ] || kt=1
hr_log_fields nudge nudge tool_name "$tool_name" bytes "$size"
hr_add_context PostToolUse "headroom: that $tool_name output was about ${kt}k tokens in the main context. headroom:scout runs this kind of work in its own context and returns only a short report."

#!/bin/sh
# headroom PostToolUse hook for Read|Bash|Grep|Glob|WebFetch|WebSearch|
# mcp__.*: counts how many bytes of tool output the main session took in
# since the last prompt and, once the total passes the reading budget,
# nudges once per prompt toward headroom:scout.
#
# Size measures what the model actually saw:
# - Bash: stdout + stderr, zero when tool_response.persistedOutputPath is set
#   (the model sees only a ~2KB preview of persisted output).
# - Read: tool_response.file.content.
# - Everything else: compact JSON of tool_response.
# Worker tool calls (agent_id set) are never counted or nudged.
#
# State: ${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/headroom}/budget-<session_id>
# holds prompt_id, read_bytes and read_nudged; a new prompt_id resets the
# counters. Updates run under a mkdir lock (20 tries, 0.05 s apart); when the
# lock stays busy the call is not counted.
# Budget: HEADROOM_READ_BUDGET bytes (default 24576, about 6k tokens); 0 turns
# the nudge off.
# Parses hook input with jq, falling back to python3. HEADROOM_PARSER=python3
# forces the python3 path (tests); HEADROOM_PARSER=none behaves as if neither
# is installed. Without a parser the hook does nothing and notes it on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

input=$(cat 2>/dev/null || true)

budget=${HEADROOM_READ_BUDGET:-24576}
case "$budget" in ''|*[!0-9]*) budget=24576 ;; esac
[ "$budget" -gt 0 ] || exit 0

parser=none
if [ "${HEADROOM_PARSER:-auto}" = none ]; then
  parser=none
elif [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
  parser=jq
elif command -v python3 >/dev/null 2>&1; then
  parser=python3
fi

case "$parser" in
  jq)
    fields=$(printf '%s' "$input" | jq -r '
      "parsed",
      (.session_id // ""),
      (.prompt_id // ""),
      (.agent_id // ""),
      (if (.tool_name // "") == "Bash" and (.tool_response.persistedOutputPath // null) != null then "skip" else "" end),
      (
        if (.tool_name // "") == "Bash" then
          (.tool_response.stdout // "") + (.tool_response.stderr // "")
        elif (.tool_name // "") == "Read" then
          (.tool_response.file.content // "")
        else
          (.tool_response | tojson)
        end
      )' 2>/dev/null)
    rc=$?
    ;;
  python3)
    fields=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
name = d.get("tool_name") or ""
tr = d.get("tool_response")
if not isinstance(tr, dict):
    tr = {}
skip = ""
if name == "Bash":
    if tr.get("persistedOutputPath") is not None:
        skip = "skip"
    measured = (tr.get("stdout") or "") + (tr.get("stderr") or "")
elif name == "Read":
    measured = (tr.get("file") or {}).get("content") or ""
else:
    measured = json.dumps(d.get("tool_response"), separators=(",", ":"), ensure_ascii=False)
print("parsed")
print(d.get("session_id") or "")
print(d.get("prompt_id") or "")
print(d.get("agent_id") or "")
print(skip)
sys.stdout.flush()
sys.stdout.buffer.write(measured.encode("utf-8"))
sys.stdout.buffer.write(b"\n")' 2>/dev/null)
    rc=$?
    ;;
  *)
    echo "headroom: neither jq nor python3 found; reading budget skipped" >&2
    exit 0
    ;;
esac

if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input; reading budget skipped" >&2
  exit 0
fi

session_id=$(printf '%s\n' "$fields" | sed -n 2p | tr -cd 'A-Za-z0-9_-')
prompt_id=$(printf '%s\n' "$fields" | sed -n 3p)
agent_id=$(printf '%s\n' "$fields" | sed -n 4p)
skip=$(printf '%s\n' "$fields" | sed -n 5p)
measured=$(printf '%s\n' "$fields" | sed -n '6,$p')

[ -z "$agent_id" ] || exit 0
[ -n "$session_id" ] || exit 0

size=0
if [ "$skip" != skip ]; then
  size=$(printf '%s' "$measured" | wc -c | tr -d '[:space:]')
fi

dir=${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/headroom}
mkdir -p "$dir" 2>/dev/null || exit 0
state="$dir/budget-$session_id"
lock="$state.lock"

tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 20 ] || exit 0
  sleep 0.05
done
trap 'rmdir "$lock" 2>/dev/null' EXIT

old_prompt=$(sed -n 's/^prompt_id=//p' "$state" 2>/dev/null | sed -n 1p)
read_bytes=$(sed -n 's/^read_bytes=//p' "$state" 2>/dev/null | sed -n 1p)
nudged=$(sed -n 's/^read_nudged=//p' "$state" 2>/dev/null | sed -n 1p)
case "$read_bytes" in ''|*[!0-9]*) read_bytes=0 ;; esac
case "$nudged" in 1) ;; *) nudged=0 ;; esac
if [ "$old_prompt" != "$prompt_id" ]; then
  read_bytes=0
  nudged=0
fi

read_bytes=$((read_bytes + size))
emit=0
if [ "$read_bytes" -gt "$budget" ] && [ "$nudged" -eq 0 ]; then
  emit=1
  nudged=1
fi

printf 'prompt_id=%s\nread_bytes=%s\nread_nudged=%s\n' "$prompt_id" "$read_bytes" "$nudged" > "$state.tmp" \
  && mv "$state.tmp" "$state"

if [ "$emit" -eq 1 ]; then
  # ~4 bytes per token.
  kt=$((read_bytes / 4096))
  [ "$kt" -gt 0 ] || kt=1
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"headroom: about %sk tokens of tool output entered the main context since the last prompt. Remaining lookups for this prompt fit headroom:scout, which reads in its own context and returns a short report."}}\n' "$kt"
fi
exit 0

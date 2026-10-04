#!/bin/sh
# headroom PreToolUse hook for Read: in the main session only, refuses a Read
# of a large file that has no small limit, so the file never enters the main
# context whole. Unlike block.sh this is ON BY DEFAULT and not tied to
# hard_blocks: a whole large file is the single biggest avoidable context
# cost, and nudge.sh only speaks after the bytes are already in. Set
# read_max_bytes to 0 to turn it off.
#
# Allowed without output: a worker's own Read (agent_id present); a Read of
# an image or pdf (png jpg jpeg gif webp pdf, any case; those go through
# vision/pages, not text); a Read with a limit of 400 lines or fewer; a file
# that is missing or not a regular file; a file under read_max_bytes
# (default 32768, the same threshold as nudge.sh). A one-time or
# session-scoped override written by inline.sh, or env HEADROOM_BLOCKS=0,
# lifts the deny, exactly as for block.sh; a benign Read never consumes a
# one-time override.
#
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it allows silently and notes the gap on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

# Same as nudge.sh's THRESHOLD (~8k tokens).
DEFAULT_MAX_BYTES=32768
# A Read with a limit at or under this many lines is a targeted range.
MAX_LIMIT_LINES=400

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.session_id // ""),
  (.agent_id // ""),
  (.tool_input.limit // "" | tostring),
  (.tool_input.file_path // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
t = d.get("tool_input") or {}
lim = t.get("limit")
print("parsed")
print(d.get("session_id") or "")
print(d.get("agent_id") or "")
print("" if lim is None else lim)
print(t.get("file_path") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); Read check skipped" >&2
  exit 0
fi

session_id=$(printf '%s\n' "$fields" | sed -n 2p)
agent_id=$(printf '%s\n' "$fields" | sed -n 3p)
limit=$(printf '%s\n' "$fields" | sed -n 4p)
# file_path is last so a path containing a newline cannot shift the fields.
file_path=$(printf '%s\n' "$fields" | sed -n '5,$p')

# Workers are never guarded.
[ -z "$agent_id" ] || exit 0

max_bytes="${CLAUDE_PLUGIN_OPTION_READ_MAX_BYTES:-$DEFAULT_MAX_BYTES}"
case "$max_bytes" in
  ''|*[!0-9]*) max_bytes=$DEFAULT_MAX_BYTES ;;
esac
[ "$max_bytes" -gt 0 ] || exit 0
[ "${HEADROOM_BLOCKS:-1}" != 0 ] || exit 0

[ -n "$file_path" ] || exit 0

ext_lc=$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')
case "$ext_lc" in
  png|jpg|jpeg|gif|webp|pdf) exit 0 ;;
esac

# A targeted range: a plain integer limit of 400 or fewer.
case "$limit" in
  ''|*[!0-9]*) : ;;
  *) if [ "$limit" -le "$MAX_LIMIT_LINES" ] 2>/dev/null; then exit 0; fi ;;
esac

[ -f "$file_path" ] || exit 0
# wc -c is portable across BSD and GNU stat flag differences.
size=$(wc -c <"$file_path" 2>/dev/null | tr -d '[:space:]')
case "$size" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$size" -ge "$max_bytes" ] || exit 0

# About to deny: check the inline override written by inline.sh.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -n "$session_id" ]; then
  override_file="$CLAUDE_PLUGIN_DATA/inline/$session_id"
  if [ -r "$override_file" ]; then
    scope=$(cat "$override_file" 2>/dev/null || true)
    case "$scope" in
      *session*)
        hr_log override read-guard "session inline override active for Read"
        exit 0
        ;;
      *once*)
        rm -f "$override_file" 2>/dev/null || true
        hr_log override read-guard "one-time inline override consumed for Read"
        exit 0
        ;;
    esac
  fi
fi

if [ "$size" -ge 1024 ]; then
  size_text="$((size / 1024)) KB"
else
  size_text="$size bytes"
fi
hr_log_fields block read-guard tool_name Read bytes "$size" detail "$file_path"
hr_deny "headroom: $file_path is ${size_text}, too large to read into the main context whole. Delegate to headroom:scout with a specific question about it, or Read a targeted range with offset and limit (at most $MAX_LIMIT_LINES lines), or ask the user to run /headroom:inline (this call only) or /headroom:inline session."
exit 0

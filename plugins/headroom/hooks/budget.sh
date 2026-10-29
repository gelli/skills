#!/bin/sh
# headroom PostToolUse hook for Read, Bash, Grep, Glob, WebFetch, WebSearch,
# Edit, Write, NotebookEdit and every mcp__ tool (anchored matcher). Two budgets per prompt, each nudging once:
# - reading: counts the bytes of tool output the main session took in since
#   the last prompt and, once the total passes the reading budget, nudges
#   toward headroom:scout.
# - doing: counts distinct files edited (Edit, Write: tool_input.file_path;
#   NotebookEdit: tool_input.notebook_path) and, once the count reaches the
#   edit budget, nudges to hand the remaining implementation to a worker.
# Edit tools add nothing to the reading bytes.
#
# Size measures what the model actually saw:
# The parser counts the bytes (UTF-8) and hands the hook one number.
# - Bash: stdout + stderr, zero when tool_response.persistedOutputPath is set
#   (the model sees only a ~2KB preview of persisted output).
# - Read: tool_response.file.content.
# - Everything else: compact JSON of tool_response.
# Worker tool calls (agent_id set) are never counted or nudged.
#
# State: ${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/headroom}/budget-<session_id>
# holds prompt_id, read_bytes, read_nudged, edit_nudged and edited_files (one
# path per line, last); a new prompt_id resets all of them. Updates run under a mkdir lock (20 tries, 0.05 s apart; a lock
# older than 10 s is removed). When the lock stays busy, or the data folder is
# not writable, the call is not counted and one stderr line says so.
# Budgets: HEADROOM_READ_BUDGET bytes (default 24576, about 6k tokens) and
# HEADROOM_EDIT_BUDGET distinct files (default 3); 0 turns a nudge off.
# Parses hook input with jq, falling back to python3. HEADROOM_PARSER=python3
# forces the python3 path (tests); HEADROOM_PARSER=none behaves as if neither
# is installed. Without a parser the hook does nothing and notes it on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

input=$(cat 2>/dev/null || true)

budget=${HEADROOM_READ_BUDGET:-24576}
case "$budget" in ''|*[!0-9]*) budget=24576 ;; esac
ebudget=${HEADROOM_EDIT_BUDGET:-3}
case "$ebudget" in ''|*[!0-9]*) ebudget=3 ;; esac
[ "$budget" -gt 0 ] || [ "$ebudget" -gt 0 ] || exit 0

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
    # Line 1 "parsed", then session_id, prompt_id, worker flag, counted bytes,
    # tool name, edited path. The ids are cut to [A-Za-z0-9_-] here so that a
    # stray newline cannot shift the lines.
    fields=$(printf '%s' "$input" | jq -r '
      def id: (. // "") | tostring | gsub("[^A-Za-z0-9_-]"; "");
      (.tool_name // "") as $t
      | (if $t == "Bash" and (.tool_response.persistedOutputPath // null) != null then 0
         elif ($t | IN("Edit", "Write", "NotebookEdit")) then 0
         elif $t == "Bash" then (((.tool_response.stdout // "") + (.tool_response.stderr // "")) | utf8bytelength)
         elif $t == "Read" then ((.tool_response.file.content // "") | utf8bytelength)
         else (.tool_response | tojson | utf8bytelength) end) as $n
      | "parsed",
        (.session_id | id),
        (.prompt_id | id),
        (if (.agent_id // "") != "" then "w" else "" end),
        $n,
        $t,
        ((if $t == "NotebookEdit" then (.tool_input.notebook_path // "") else (.tool_input.file_path // "") end) | tostring | gsub("[\r\n]"; " "))' 2>/dev/null)
    rc=$?
    ;;
  python3)
    fields=$(printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
def ident(v):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(v or ""))
name = d.get("tool_name") or ""
tr = d.get("tool_response")
if not isinstance(tr, dict):
    tr = {}
ti = d.get("tool_input")
if not isinstance(ti, dict):
    ti = {}
path = ti.get("notebook_path" if name == "NotebookEdit" else "file_path") or ""
if not isinstance(path, str):
    path = ""
path = path.replace("\r", " ").replace("\n", " ")
if name in ("Edit", "Write", "NotebookEdit"):
    n = 0
elif name == "Bash":
    if tr.get("persistedOutputPath") is not None:
        n = 0
    else:
        n = len(((tr.get("stdout") or "") + (tr.get("stderr") or "")).encode("utf-8"))
elif name == "Read":
    n = len(((tr.get("file") or {}).get("content") or "").encode("utf-8"))
else:
    n = len(json.dumps(d.get("tool_response"), separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
print("parsed")
print(ident(d.get("session_id")))
print(ident(d.get("prompt_id")))
print("w" if d.get("agent_id") else "")
print(n)
print(name)
print(path)' 2>/dev/null)
    rc=$?
    ;;
  *)
    echo "headroom: neither jq nor python3 found; budget skipped" >&2
    exit 0
    ;;
esac

if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input; budget skipped" >&2
  exit 0
fi

session_id=$(printf '%s\n' "$fields" | sed -n 2p | tr -cd 'A-Za-z0-9_-')
prompt_id=$(printf '%s\n' "$fields" | sed -n 3p | tr -cd 'A-Za-z0-9_-')
agent_id=$(printf '%s\n' "$fields" | sed -n 4p)
size=$(printf '%s\n' "$fields" | sed -n 5p)
tool=$(printf '%s\n' "$fields" | sed -n 6p)
epath=$(printf '%s\n' "$fields" | sed -n 7p)
case "$size" in ''|*[!0-9]*) size=0 ;; esac
case "$tool" in Edit|Write|NotebookEdit) is_edit=1 ;; *) is_edit=0 ;; esac

[ -z "$agent_id" ] || exit 0
[ -n "$session_id" ] || exit 0
if [ "$is_edit" -eq 1 ]; then
  [ "$ebudget" -gt 0 ] || exit 0
  [ -n "$epath" ] || exit 0
else
  [ "$budget" -gt 0 ] || exit 0
fi

dir=${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/headroom}
if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
  echo "headroom: data folder $dir is not writable; budget skipped" >&2
  exit 0
fi
state="$dir/budget-$session_id"
lock="$state.lock"

# mtime of a path in epoch seconds (GNU stat, then BSD stat).
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

tries=0
until mkdir "$lock" 2>/dev/null; do
  m=$(mtime "$lock")
  case "$m" in
    ''|*[!0-9]*) ;;
    *) if [ $(( $(date +%s) - m )) -gt 10 ]; then rmdir "$lock" 2>/dev/null; continue; fi ;;
  esac
  tries=$((tries + 1))
  if [ "$tries" -ge 20 ]; then
    echo "headroom: budget lock busy; call not counted" >&2
    exit 0
  fi
  sleep 0.05
done
trap 'rmdir "$lock" 2>/dev/null' EXIT

old_prompt=
read_bytes=
nudged=
edit_nudged=
edited=
if [ -f "$state" ]; then
  while IFS= read -r line; do
    case "$line" in
      prompt_id=*) old_prompt=${line#prompt_id=} ;;
      read_bytes=*) read_bytes=${line#read_bytes=} ;;
      read_nudged=*) nudged=${line#read_nudged=} ;;
      edit_nudged=*) edit_nudged=${line#edit_nudged=} ;;
      edited_files=*)
        p=${line#edited_files=}
        if [ -n "$edited" ]; then edited="$edited
$p"; else edited=$p; fi ;;
    esac
  done < "$state"
fi
case "$read_bytes" in ''|*[!0-9]*) read_bytes=0 ;; esac
case "$nudged" in 1) ;; *) nudged=0 ;; esac
case "$edit_nudged" in 1) ;; *) edit_nudged=0 ;; esac
if [ "$old_prompt" != "$prompt_id" ]; then
  read_bytes=0
  nudged=0
  edit_nudged=0
  edited=
fi

emit=0
emit_edit=0
n_edited=0
if [ "$is_edit" -eq 1 ]; then
  if ! printf '%s\n' "$edited" | grep -qxF -- "$epath"; then
    if [ -n "$edited" ]; then edited="$edited
$epath"; else edited=$epath; fi
  fi
  n_edited=$(printf '%s\n' "$edited" | grep -c .)
  if [ "$n_edited" -ge "$ebudget" ] && [ "$edit_nudged" -eq 0 ]; then
    emit_edit=1
    edit_nudged=1
  fi
else
  read_bytes=$((read_bytes + size))
  if [ "$read_bytes" -gt "$budget" ] && [ "$nudged" -eq 0 ]; then
    emit=1
    nudged=1
  fi
fi

{
  printf 'prompt_id=%s\nread_bytes=%s\nread_nudged=%s\nedit_nudged=%s\n' "$prompt_id" "$read_bytes" "$nudged" "$edit_nudged"
  # Paths are stored one per line after the last key; each line is prefixed so
  # the sed reader above collects every line.
  printf '%s\n' "$edited" | sed '/^$/d; s/^/edited_files=/'
} > "$state.tmp" && mv "$state.tmp" "$state"

if [ "$emit" -eq 1 ]; then
  # ~4 bytes per token.
  kt=$((read_bytes / 4096))
  [ "$kt" -gt 0 ] || kt=1
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"headroom: about %sk tokens of tool output entered the main context since the last prompt. Remaining lookups for this prompt fit headroom:scout, which reads in its own context and returns a short report."}}\n' "$kt"
fi
if [ "$emit_edit" -eq 1 ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"headroom: this prompt has now edited %s files in the main session. Hand the remaining implementation to a worker (general-purpose, model sonnet) with a brief, and review its diff here."}}\n' "$n_edited"
fi
exit 0

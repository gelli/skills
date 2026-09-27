#!/bin/sh
# Shared helpers for headroom hook scripts. Sourced, never executed directly.
#
# - hr_read_input / hr_fields: JSON field extraction with jq, falling back to
#   python3 (HEADROOM_PARSER=python3 forces the python3 path, used by tests).
#   Callers pass one jq filter and one equivalent python3 snippet; both must
#   print "parsed" on the first line, then one field per line in the same
#   order. hr_fields returns non-zero if neither parser is available or the
#   input does not parse as JSON; the caller should then allow the call and
#   note the gap on stderr, exactly like model-routing does.
# - hr_json_escape: JSON-quotes a string. Only ever called after hr_fields has
#   already proven jq or python3 works, so it never needs its own fallback
#   for a missing parser.
# - hr_deny / hr_add_context: print the hook-output JSON shapes.
# - hr_log: appends one JSON line to the headroom event log, best-effort.
# - hr_log_fields: like hr_log, but for an arbitrary set of key/value fields
#   (usage numbers, sizes) plus session_id, read from $HR_INPUT when set.
# - hr_log_rotate: called by both of the above before they append, so the
#   log is capped at HR_LOG_MAX_BYTES (Phase 2 risk: "the log grows without
#   limit").
set -u

# headroom.log.jsonl's size cap: once a write would find it at or over this
# size, hr_log_rotate moves it to headroom.log.jsonl.1 first (overwriting
# any previous one), so it never grows without bound. 10 MB is generous: a
# logged line here runs a few hundred bytes, so the cap holds many weeks of
# normal use, well past the 7-day window usage.sh reports on by default.
# Tests override this by reassigning it after sourcing lib.sh.
HR_LOG_MAX_BYTES=10485760

hr_read_input() {
  HR_INPUT=$(cat 2>/dev/null || true)
}

# hr_fields <jq-filter> <python3-code>
hr_fields() {
  jqf=$1
  pyc=$2
  if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$HR_INPUT" | jq -r "$jqf" 2>/dev/null
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$HR_INPUT" | python3 -c "$pyc" 2>/dev/null
    return $?
  fi
  return 127
}

# hr_json_escape <raw string> -> a JSON string literal, quotes included.
hr_json_escape() {
  if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# hr_deny <reason> -- a PreToolUse deny decision.
hr_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(hr_json_escape "$1")"
}

# hr_add_context <hookEventName> <message> -- a PostToolUse/SubagentStop
# additionalContext decision.
hr_add_context() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' "$1" "$(hr_json_escape "$2")"
}

# hr_block <reason> -- a Stop/SubagentStop block decision. This is a
# top-level field, not hookSpecificOutput: it keeps the (sub)agent running
# and delivers <reason> to it as its next instruction.
hr_block() {
  printf '{"decision":"block","reason":%s}\n' "$(hr_json_escape "$1")"
}

# hr_log_rotate <path> -- best-effort: once <path> is at or over
# HR_LOG_MAX_BYTES, renames it to <path>.1 (overwriting any previous one),
# so the log never grows without bound. Called by hr_log and hr_log_fields
# right before they append, so every write checks it. This is simple
# rotation, not locked: two writers hitting the cap at the same instant
# (e.g. Stop and a SubagentStop landing together) can both see the old size
# and both mv, so the second mv can overwrite the first's freshly-rotated
# (near-empty) .1 with its own, losing the archive rather than a single
# line. Accepted for a best-effort log; never fails the caller.
hr_log_rotate() {
  hr_lr_path=$1
  [ -f "$hr_lr_path" ] || return 0
  hr_lr_size=$(wc -c <"$hr_lr_path" 2>/dev/null | tr -d '[:space:]')
  case "$hr_lr_size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$hr_lr_size" -ge "$HR_LOG_MAX_BYTES" ] || return 0
  mv -f "$hr_lr_path" "$hr_lr_path.1" 2>/dev/null || true
}

# hr_log <event> <hook> <detail> -- best-effort append to
# $CLAUDE_PLUGIN_DATA/headroom.log.jsonl. Silently does nothing if the
# variable is unset or the file cannot be written; never fails the hook.
hr_log() {
  data="${CLAUDE_PLUGIN_DATA:-}"
  [ -n "$data" ] || return 0
  mkdir -p "$data" 2>/dev/null || return 0
  hr_log_rotate "$data/headroom.log.jsonl"
  ts=$(date +%s 2>/dev/null || echo 0)
  printf '{"ts":%s,"event":%s,"hook":%s,"detail":%s}\n' \
    "$ts" "$(hr_json_escape "$1")" "$(hr_json_escape "$2")" "$(hr_json_escape "$3")" \
    >>"$data/headroom.log.jsonl" 2>/dev/null || return 0
}

# hr_log_fields <event> <hook> [<key> <value> ...] -- best-effort append to
# $CLAUDE_PLUGIN_DATA/headroom.log.jsonl, like hr_log, but for an arbitrary
# set of extra fields (usage numbers, sizes) instead of one detail string.
# session_id is read from $HR_INPUT (set by hr_read_input) when present;
# it is always present in the logged line, empty if not found.
#
# A value is logged unquoted (as JSON true/false/a number) when it is
# exactly "true", "false", or a non-negative integer with no leading zero
# ("0" itself is the one exception); everything else, including "007" and
# "", goes through hr_json_escape as a string. An odd trailing key with no
# value logs as "".
hr_log_fields() {
  hr_lf_event=$1
  hr_lf_hook=$2
  shift 2
  hr_lf_data="${CLAUDE_PLUGIN_DATA:-}"
  [ -n "$hr_lf_data" ] || return 0
  mkdir -p "$hr_lf_data" 2>/dev/null || return 0
  hr_log_rotate "$hr_lf_data/headroom.log.jsonl"
  hr_lf_ts=$(date +%s 2>/dev/null || echo 0)

  hr_sid=""
  if [ -n "${HR_INPUT:-}" ]; then
    hr_lf_sid_out=$(hr_fields '
      "parsed",
      (.session_id // "")
    ' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("parsed")
print(d.get("session_id") or "")
')
    if [ "$(printf '%s\n' "$hr_lf_sid_out" | sed -n 1p)" = parsed ]; then
      hr_sid=$(printf '%s\n' "$hr_lf_sid_out" | sed -n 2p)
    fi
  fi

  hr_extra=""
  while [ $# -gt 0 ]; do
    hr_k=$1
    shift
    if [ $# -gt 0 ]; then
      hr_v=$1
      shift
    else
      hr_v=""
    fi
    case "$hr_v" in
      true|false) hr_v_json=$hr_v ;;
      0) hr_v_json=0 ;;
      0*) hr_v_json=$(hr_json_escape "$hr_v") ;;
      ''|*[!0-9]*) hr_v_json=$(hr_json_escape "$hr_v") ;;
      *) hr_v_json=$hr_v ;;
    esac
    hr_extra="$hr_extra,$(hr_json_escape "$hr_k"):$hr_v_json"
  done

  printf '{"ts":%s,"event":%s,"hook":%s,"session_id":%s%s}\n' \
    "$hr_lf_ts" "$(hr_json_escape "$hr_lf_event")" "$(hr_json_escape "$hr_lf_hook")" "$(hr_json_escape "$hr_sid")" "$hr_extra" \
    >>"$hr_lf_data/headroom.log.jsonl" 2>/dev/null || return 0
}

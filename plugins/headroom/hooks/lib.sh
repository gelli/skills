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
set -u

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

# hr_log <event> <hook> <detail> -- best-effort append to
# $CLAUDE_PLUGIN_DATA/headroom.log.jsonl. Silently does nothing if the
# variable is unset or the file cannot be written; never fails the hook.
hr_log() {
  data="${CLAUDE_PLUGIN_DATA:-}"
  [ -n "$data" ] || return 0
  mkdir -p "$data" 2>/dev/null || return 0
  ts=$(date +%s 2>/dev/null || echo 0)
  printf '{"ts":%s,"event":%s,"hook":%s,"detail":%s}\n' \
    "$ts" "$(hr_json_escape "$1")" "$(hr_json_escape "$2")" "$(hr_json_escape "$3")" \
    >>"$data/headroom.log.jsonl" 2>/dev/null || return 0
}

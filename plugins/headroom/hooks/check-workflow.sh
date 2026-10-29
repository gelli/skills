#!/bin/sh
# headroom PreToolUse hook for the Workflow tool.
# Denies a workflow run whose script requests fable or mythos as an agent
# model (`model: 'fable'`). The script comes from tool_input.script, or from
# the file tool_input.scriptPath when script is empty. Named workflows and
# scripts without such a model pass through. It also denies a script in which
# any agent() call lacks a literal `model` option key (text in strings and
# comments does not count). Unparseable input is allowed.
# Needs jq or python3; HEADROOM_PARSER=python3 forces the python3 path.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

input=$(cat 2>/dev/null || true)

if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
  script=$(printf '%s' "$input" | jq -r '.tool_input.script // ""' 2>/dev/null) || exit 0
  path=$(printf '%s' "$input" | jq -r '.tool_input.scriptPath // ""' 2>/dev/null) || exit 0
elif command -v python3 >/dev/null 2>&1; then
  script=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin).get("tool_input") or {}
except Exception:
    sys.exit(1)
sys.stdout.write(t.get("script") or "")' 2>/dev/null) || exit 0
  path=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin).get("tool_input") or {}
except Exception:
    sys.exit(1)
sys.stdout.write(t.get("scriptPath") or "")' 2>/dev/null) || exit 0
else
  echo "headroom: neither jq nor python3 found; Workflow model check skipped" >&2
  exit 0
fi

if [ -z "$script" ] && [ -n "$path" ] && [ -f "$path" ]; then
  script=$(cat "$path" 2>/dev/null || true)
fi
[ -z "$script" ] && exit 0

flat=$(printf '%s' "$script" | tr '\n\r\t' '   ')

if printf '%s' "$flat" | grep -Eiq "model[[:space:]]*:[[:space:]]*['\"\`][^'\"\`]*(fable|mythos)"; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"headroom: this workflow'"'"'s script requests fable or mythos as an agent model. Fable is orchestrator-only; set the model to haiku, sonnet or opus."}}'
  exit 0
fi

# Every agent() call (start of script or a non-identifier character before
# it) needs `model` as an option key (`model:`, or the shorthand `model,` /
# `model}`) before the next agent( call. The lexer first blanks the contents
# of '...', "..." and template literals (code inside ${...} stays) and drops
# // and /* */ comments, so text in strings and comments counts for nothing.
# Newlines travel as \001 so that // comments end at the right place.
missing=$(printf '%s' "$script" | tr '\n\r\t' '\001  ' | awk '
  function lex(s,    n, i, c, d, mode, out, sp, bd) {
    n = length(s); mode = "code"; out = ""; sp = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); d = substr(s, i + 1, 1)
      if (mode == "code") {
        if (c == "\047") { mode = "sq"; out = out c }
        else if (c == "\042") { mode = "dq"; out = out c }
        else if (c == "`") { mode = "tpl"; out = out c }
        else if (c == "/" && d == "/") { mode = "line"; i++; out = out " " }
        else if (c == "/" && d == "*") { mode = "block"; i++; out = out " " }
        else if (c == "{") { if (sp > 0) bd[sp]++; out = out c }
        else if (c == "}") {
          if (sp > 0 && bd[sp] == 0) { sp--; mode = "tpl"; out = out " " }
          else { if (sp > 0) bd[sp]--; out = out c }
        }
        else out = out c
      } else if (mode == "sq" || mode == "dq" || mode == "tpl") {
        if (c == "\\") i++
        else if (mode == "sq" && c == "\047") { mode = "code"; out = out c }
        else if (mode == "dq" && c == "\042") { mode = "code"; out = out c }
        else if (mode == "tpl" && c == "`") { mode = "code"; out = out c }
        else if (mode == "tpl" && c == "$" && d == "{") { sp++; bd[sp] = 0; mode = "code"; i++; out = out " " }
      } else if (mode == "line") {
        if (c == "\001") { mode = "code"; out = out " " }
      } else if (mode == "block") {
        if (c == "*" && d == "/") { mode = "code"; i++; out = out " " }
      }
    }
    return out
  }
  function seg_ok(t) { return t ~ /(^|[^A-Za-z0-9_$])model[ ]*[:,}]/ }
  {
    s = lex($0); gsub(/\001/, " ", s); bad = 0
    pat = "(^|[^A-Za-z0-9_$])agent[ ]*[(]"
    if (!match(s, pat)) { print 0; exit }
    s = substr(s, RSTART + RLENGTH)
    while (1) {
      if (match(s, pat)) {
        if (!seg_ok(substr(s, 1, RSTART))) bad = 1
        s = substr(s, RSTART + RLENGTH)
      } else {
        if (!seg_ok(s)) bad = 1
        break
      }
    }
    print bad
  }')
if [ "$missing" = 1 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"headroom: an agent() call in this workflow names no model, so it would inherit the session model. Give every agent() call an explicit model (haiku, sonnet or opus); write the model literally in each call'"'"'s options, since this check cannot follow a model passed through a variable."}}'
fi
exit 0

#!/bin/sh
# Replays the Agent guard against every input case on both parser paths
# (jq, python3) and checks the SessionStart injector. Run from anywhere:
#   sh plugins/headroom/tests/test-hooks.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
guard="$root/hooks/check-agent.sh"
inject="$root/hooks/inject-rules.sh"
wfguard="$root/hooks/check-workflow.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fail=1; fi
}

# decision <json> -> allow | deny | skip (stderr note, no stdout)
decision() {
  out=$(printf '%s' "$1" | "$guard" 2>/dev/null)
  case "$out" in
    "") printf 'allow' ;;
    *'"permissionDecision":"deny"'*) printf 'deny' ;;
    *) printf 'other' ;;
  esac
}

run_matrix() { # label
  echo "$1"
  check "prompt only, no model"     deny  "$(decision '{"tool_input":{"prompt":"x","description":"y"}}')"
  check "empty tool_input"          deny  "$(decision '{"tool_input":{}}')"
  check "model null"                deny  "$(decision '{"tool_input":{"model":null,"subagent_type":"general-purpose"}}')"
  check "model in prompt text only" deny  "$(decision '{"tool_input":{"prompt":"model: haiku","subagent_type":"general-purpose"}}')"
  check "model fable"               deny  "$(decision '{"tool_input":{"model":"fable"}}')"
  check "fork with model"           deny  "$(decision '{"tool_input":{"subagent_type":"fork","model":"sonnet"}}')"
  check "model haiku"               allow "$(decision '{"tool_input":{"model":"haiku"}}')"
  check "model sonnet"              allow "$(decision '{"tool_input":{"model":"sonnet","subagent_type":"browser-scout"}}')"
  check "model opus"                allow "$(decision '{"tool_input":{"model":"opus"}}')"
  check "scout, no model"           deny  "$(decision '{"tool_input":{"subagent_type":"scout"}}')"
  check "headroom:scout, no model"  allow "$(decision '{"tool_input":{"subagent_type":"headroom:scout"}}')"
  check "headroom:scout, null model" allow "$(decision '{"tool_input":{"subagent_type":"headroom:scout","model":null}}')"
  check "headroom:scout, model fable" deny "$(decision '{"tool_input":{"subagent_type":"headroom:scout","model":"fable"}}')"
  check "general-purpose, no model" deny  "$(decision '{"tool_input":{"subagent_type":"general-purpose"}}')"
  check "unparseable input"         allow "$(decision 'not json')"
  check "empty input"               allow "$(decision '')"
}

if command -v jq >/dev/null 2>&1; then
  run_matrix "guard via jq"
  echo "  deny output is valid JSON with a reason:"
  reason=$(printf '{"tool_input":{}}' | "$guard" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
  case "$reason" in "headroom:"*) echo "  ok    reason text" ;; *) echo "  FAIL  reason text: '$reason'"; fail=1 ;; esac
else
  echo "jq not installed; skipping jq path"
fi

if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_matrix "guard via python3"
  echo "  python3 path really parses:"
  out=$(printf '{"tool_input":{"model":"opus"}}' | HEADROOM_PARSER=python3 "$guard" 2>&1)
  check "no parse-failure note on stderr" "" "$out"
else
  echo "python3 not installed; skipping python3 path"
fi

wf_decision() { # <json> -> allow | deny | other
  out=$(printf '%s' "$1" | "$wfguard" 2>/dev/null)
  case "$out" in
    "") printf 'allow' ;;
    *'"permissionDecision":"deny"'*) printf 'deny' ;;
    *) printf 'other' ;;
  esac
}

workflow_matrix() { # label
  echo "$1"
  printf "agent('x', { model: 'fable' })\n" > "$tmp/fable.js"
  check "inline model fable"        deny  "$(wf_decision '{"tool_input":{"script":"agent(\"x\", { model: \u0027fable\u0027 })"}}')"
  check "inline model mythos"       deny  "$(wf_decision '{"tool_input":{"script":"agent(\"x\", { model: \"mythos\" })"}}')"
  check "model split across lines"  deny  "$(wf_decision '{"tool_input":{"script":"agent(\"x\", { model:\n  \u0027fable\u0027 })"}}')"
  check "scriptPath with fable"     deny  "$(wf_decision "{\"tool_input\":{\"scriptPath\":\"$tmp/fable.js\"}}")"
  check "named workflow"            allow "$(wf_decision '{"tool_input":{"name":"review-changes"}}')"
  check "all agents sonnet"         allow "$(wf_decision '{"tool_input":{"script":"agent(\"a\", { model: \u0027sonnet\u0027 }); agent(\"b\", { model: \u0027sonnet\u0027 })"}}')"
  check "unparseable input"         allow "$(wf_decision 'not json')"
}

if command -v jq >/dev/null 2>&1; then
  workflow_matrix "workflow guard via jq"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 workflow_matrix "workflow guard via python3"
fi

echo "injector"
out=$(CLAUDE_PLUGIN_ROOT="$root" "$inject" </dev/null)
case "$out" in "<headroom>"*"</headroom>") echo "  ok    wrapped in <headroom> tags" ;; *) echo "  FAIL  tag wrapping"; fail=1 ;; esac
case "$out" in *"# Headroom"*) echo "  ok    contains rules.md" ;; *) echo "  FAIL  rules.md missing"; fail=1 ;; esac
check "empty plugin root prints nothing" "" "$(CLAUDE_PLUGIN_ROOT=/nonexistent "$inject" </dev/null)"

[ $fail -eq 0 ] && echo "all hook tests passed" || { echo "hook tests FAILED"; exit 1; }

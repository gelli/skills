#!/bin/sh
# Replays the Agent guard against every input case on both parser paths
# (jq, python3) and checks the SessionStart injector. Run from anywhere:
#   sh plugins/model-routing/tests/test-hooks.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
guard="$root/hooks/check-agent-model.sh"
inject="$root/hooks/inject-rules.sh"
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
  check "unparseable input"         allow "$(decision 'not json')"
  check "empty input"               allow "$(decision '')"
}

if command -v jq >/dev/null 2>&1; then
  run_matrix "guard via jq"
  echo "  deny output is valid JSON with a reason:"
  reason=$(printf '{"tool_input":{}}' | "$guard" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
  case "$reason" in *"no model parameter"*) echo "  ok    reason text" ;; *) echo "  FAIL  reason text: '$reason'"; fail=1 ;; esac
else
  echo "jq not installed; skipping jq path"
fi

if command -v python3 >/dev/null 2>&1; then
  MODEL_ROUTING_PARSER=python3 run_matrix "guard via python3"
  echo "  python3 path really parses:"
  out=$(printf '{"tool_input":{"model":"opus"}}' | MODEL_ROUTING_PARSER=python3 "$guard" 2>&1)
  check "no parse-failure note on stderr" "" "$out"
else
  echo "python3 not installed; skipping python3 path"
fi

echo "injector"
out=$(CLAUDE_PLUGIN_ROOT="$root" "$inject" </dev/null)
case "$out" in "<model-routing>"*"</model-routing>") echo "  ok    wrapped in <model-routing> tags" ;; *) echo "  FAIL  tag wrapping"; fail=1 ;; esac
case "$out" in *"# Model routing"*) echo "  ok    contains routing.md" ;; *) echo "  FAIL  routing.md missing"; fail=1 ;; esac
check "empty plugin root prints nothing" "" "$(CLAUDE_PLUGIN_ROOT=/nonexistent "$inject" </dev/null)"

[ $fail -eq 0 ] && echo "all hook tests passed" || { echo "hook tests FAILED"; exit 1; }

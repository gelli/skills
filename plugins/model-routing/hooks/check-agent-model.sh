#!/bin/sh
# model-routing PreToolUse hook for the Agent tool.
# Denies a spawn when it would run on the orchestrator's model:
#   - subagent_type "fork" (forks always inherit the parent model)
#   - no model parameter (omitted model inherits the session model)
#   - model "fable" (Fable is orchestrator-only)
# Anything else passes through untouched. The denial reason is fed back to
# Claude so it can re-issue the call with an explicit model.
# Needs jq or python3 to parse the hook input; with neither it allows the call
# and notes the gap on stderr. MODEL_ROUTING_PARSER=python3 forces the python3
# path (used by tests/test-hooks.sh).
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

input=$(cat 2>/dev/null || true)

if [ "${MODEL_ROUTING_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
  fields=$(printf '%s' "$input" | jq -r '
    "parsed\n" + (.tool_input.subagent_type // "") + "\n" + (.tool_input.model // "")' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  fields=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin).get("tool_input") or {}
except Exception:
    sys.exit(1)
print("parsed")
print(t.get("subagent_type") or "")
print(t.get("model") or "")' 2>/dev/null)
else
  echo "model-routing: neither jq nor python3 found; Agent model check skipped" >&2
  exit 0
fi

if [ "$(printf '%s\n' "$fields" | sed -n 1p)" != "parsed" ]; then
  echo "model-routing: could not parse hook input; Agent model check skipped" >&2
  exit 0
fi

subagent_type=$(printf '%s\n' "$fields" | sed -n 2p)
model=$(printf '%s\n' "$fields" | sed -n 3p)

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

case "$subagent_type" in
  fork) deny "model-routing: subagent_type \\\"fork\\\" is not allowed. A fork always inherits the orchestrator model and ignores the model parameter. Spawn a fresh agent with a written brief (GOAL, CONTEXT, SCOPE, RETURN) and an explicit model: haiku, sonnet, or opus." ;;
esac

case "$model" in
  "") deny "model-routing: Agent call has no model parameter, so the subagent would inherit the orchestrator model. Re-issue the call with model: haiku (mechanical, high-volume), sonnet (engineering judgment, the implementation floor), or opus (only when the task needs top-tier reasoning, is fully briefable, and isolation or parallelism pays)." ;;
  fable) deny "model-routing: model \\\"fable\\\" is not allowed for subagents. Fable is orchestrator-only. Use haiku, sonnet, or opus." ;;
esac

exit 0

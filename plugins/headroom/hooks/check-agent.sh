#!/bin/sh
# headroom PreToolUse hook for the Agent tool.
# Denies a spawn when it would run on the orchestrator's model:
#   - subagent_type "fork" (forks always inherit the parent model)
#   - no model parameter (omitted model inherits the session model), except
#     for subagent_type "headroom:scout", which pins its own model
#   - model "fable" (Fable is orchestrator-only)
# Anything else passes through untouched. The denial reason is fed back to
# Claude so it can re-issue the call with an explicit model.
# Needs jq or python3 to parse the hook input; with neither it allows the call
# and notes the gap on stderr. HEADROOM_PARSER=python3 forces the python3
# path (used by tests/test-hooks.sh); HEADROOM_PARSER=none behaves as if
# neither is installed.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

input=$(cat 2>/dev/null || true)

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
      "parsed\n" + (.tool_input.subagent_type // "") + "\n" + (.tool_input.model // "")' 2>/dev/null)
    ;;
  python3)
    fields=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin).get("tool_input") or {}
except Exception:
    sys.exit(1)
print("parsed")
print(t.get("subagent_type") or "")
print(t.get("model") or "")' 2>/dev/null)
    ;;
  *)
    echo "headroom: neither jq nor python3 found; Agent model check skipped" >&2
    exit 0
    ;;
esac

if [ "$(printf '%s\n' "$fields" | sed -n 1p)" != "parsed" ]; then
  echo "headroom: could not parse hook input; Agent model check skipped" >&2
  exit 0
fi

subagent_type=$(printf '%s\n' "$fields" | sed -n 2p)
model=$(printf '%s\n' "$fields" | sed -n 3p)

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

case "$subagent_type" in
  fork) deny "headroom: subagent_type \\\"fork\\\" is not allowed. A fork always inherits the orchestrator model and ignores the model parameter. Spawn a fresh agent with a written brief (GOAL, CONTEXT, SCOPE, RETURN) and an explicit model: haiku, sonnet, or opus." ;;
esac

# The scout agent pins its own model in its frontmatter, so it needs no
# model parameter. An explicit model (including fable) still gets checked.
[ "$subagent_type" = "headroom:scout" ] && [ -z "$model" ] && exit 0

case "$model" in
  "") deny "headroom: Agent call has no model parameter, so the subagent would inherit the orchestrator model. Re-issue the call with model: haiku (mechanical, high-volume), sonnet (engineering judgment, the implementation floor), or opus (only when the task needs top-tier reasoning, is fully briefable, and isolation or parallelism pays)." ;;
  fable) deny "headroom: model \\\"fable\\\" is not allowed for subagents. Fable is orchestrator-only. Use haiku, sonnet, or opus." ;;
esac

exit 0

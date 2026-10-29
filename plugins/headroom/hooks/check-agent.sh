#!/bin/sh
# headroom PreToolUse hook for the Agent tool.
# Denies a spawn when it would run on the orchestrator's model or effort,
# for every subagent type:
#   - subagent_type "fork" (forks always inherit the parent model)
#   - no model parameter (omitted model inherits the session model)
#   - model "fable" (Fable is orchestrator-only)
#   - a missing or invalid effort (valid: low, medium, high, xhigh, max)
# Anything else passes through untouched. The denial reason is fed back to
# Claude so it can re-issue the call with an explicit model and effort.
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
      "parsed\n" + (.tool_input.subagent_type // "") + "\n" + (.tool_input.model // "") + "\n" + (.tool_input.effort // "")' 2>/dev/null)
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
print(t.get("model") or "")
print(t.get("effort") or "")' 2>/dev/null)
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
effort=$(printf '%s\n' "$fields" | sed -n 4p)

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

case "$subagent_type" in
  fork) deny "headroom: subagent_type \\\"fork\\\" is not allowed. A fork always inherits the orchestrator model and ignores the model parameter. Spawn a fresh agent with a written brief (GOAL, CONTEXT, SCOPE, RETURN) and an explicit model (haiku, sonnet, or opus) and an effort (low, medium, high, xhigh, or max)." ;;
esac

case "$model" in
  "") deny "headroom: Agent call has no model parameter, so the subagent would run on the session model (or CLAUDE_CODE_SUBAGENT_MODEL, when set). Re-issue the call with model: haiku (mechanical, high-volume), sonnet (engineering judgment, the implementation floor), or opus (only when the task needs top-tier reasoning, is fully briefable, and isolation or parallelism pays). The call also needs an effort: low, medium, high, xhigh, or max." ;;
  fable) deny "headroom: model \\\"fable\\\" is not allowed for subagents. Fable is orchestrator-only. Use an explicit model (haiku, sonnet, or opus) and an effort (low, medium, high, xhigh, or max)." ;;
esac

case "$effort" in
  low|medium|high|xhigh|max) ;;
  *) deny "headroom: Agent call has no valid effort parameter, so the subagent would run at the session's effort level. Re-issue the call with effort low, medium, high, xhigh or max, paired per the tiers: haiku medium (low for a single test, build or lint run), sonnet medium (high for spec, security and concurrency reviews), opus medium (high for the final review)." ;;
esac

exit 0

#!/bin/sh
# headroom PreToolUse hook for the Agent tool: enforces that a role (scout,
# implementer, reviewer) may only be spawned at its default model or higher,
# never lower, never fable/mythos, never "inherit", and never via
# subagent_type "fork". A role also may not be spawned with "name" set: that
# would make it an agent-teams teammate rather than a worker. Explore
# inherits the main session's model, capped at Opus, not its own; it and
# Plan pass through unchecked for now (denying a model-less Explore/Plan
# spawn is deferred until there is usage data). subagent_type empty,
# "general-purpose", or "claude" need an explicit model. Any other named
# agent type is left to its own definition.
#
# Rank: haiku=1, sonnet=2, opus=3, classified by case-insensitive substring so
# full model IDs work too (claude-opus-5-5, us.anthropic.claude-haiku-4-5...,
# "opus[1m]"). Role defaults: scout=haiku, implementer=sonnet, reviewer=sonnet.
#
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it allows silently and notes the gap on stderr.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.tool_input.subagent_type // ""),
  (.tool_input.model // ""),
  (.tool_input.name // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
t = d.get("tool_input") or {}
print("parsed")
print(t.get("subagent_type") or "")
print(t.get("model") or "")
print(t.get("name") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); Agent check skipped" >&2
  exit 0
fi

subagent_type=$(printf '%s\n' "$fields" | sed -n 2p)
model=$(printf '%s\n' "$fields" | sed -n 3p)
name=$(printf '%s\n' "$fields" | sed -n 4p)
model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
role=${subagent_type#headroom:}

deny_and_log() { # reason
  hr_log deny check-agent "$1"
  hr_deny "$1"
  exit 0
}

# 1. A fork always inherits the parent model.
if [ "$subagent_type" = fork ]; then
  deny_and_log "headroom: subagent_type \"fork\" is not allowed. A fork always inherits the orchestrator model and ignores the model parameter. Spawn headroom:scout, headroom:implementer, or headroom:reviewer with a written brief instead."
fi

# 2. Fable and Mythos are orchestrator/advisor-only.
case "$model_lc" in
  *fable*|*mythos*)
    deny_and_log "headroom: model \"$model\" is not allowed for subagents. Fable and Mythos are orchestrator/advisor-only. Use haiku, sonnet, or opus, or omit model to use the role's default."
    ;;
esac

# 3. "inherit" would silently take on the orchestrator's model.
if [ "$model_lc" = inherit ]; then
  deny_and_log "headroom: model \"inherit\" is not allowed. Re-issue the call with an explicit model: haiku, sonnet, or opus, or omit model to use the role's default."
fi

rank_of() {
  case "$1" in
    *opus*) echo 3 ;;
    *sonnet*) echo 2 ;;
    *haiku*) echo 1 ;;
    *) echo "" ;;
  esac
}

case "$role" in
  scout|implementer|reviewer)
    # 3b. headroom roles are workers, not agent-teams teammates: a "name"
    # would spawn one, and a teammate built from a role's definition may not
    # keep its disallowedTools limit.
    if [ -n "$name" ]; then
      deny_and_log "headroom: headroom:$role was spawned with \"name\" set, which would make it an agent-teams teammate instead of a worker. Drop \"name\" and re-issue the call as a plain worker spawn."
    fi
    if [ "$role" = scout ]; then
      default_rank=1
      default_name=haiku
    else
      default_rank=2
      default_name=sonnet
    fi
    [ -n "$model" ] || exit 0
    rank=$(rank_of "$model_lc")
    if [ -z "$rank" ]; then
      echo "headroom: model \"$model\" for headroom:$role is not a recognised tier (haiku/sonnet/opus); allowing it through unchecked" >&2
      exit 0
    fi
    if [ "$rank" -ge "$default_rank" ]; then
      exit 0
    fi
    deny_and_log "headroom: headroom:$role's default model is $default_name; roles may only be raised, never lowered. Re-issue with model omitted (uses $default_name) or raised to sonnet or opus."
    ;;
  Explore|Plan)
    # Explore actually runs on the main session's model (capped at Opus), not
    # its own. Denying a model-less spawn here is deferred to plan item 4.7,
    # once logs show how often Explore runs on Opus in practice.
    exit 0
    ;;
  ""|general-purpose|claude)
    if [ -z "$model" ]; then
      deny_and_log "headroom: subagent_type \"$subagent_type\" has no default model, so it would inherit the orchestrator model. Re-issue the call with an explicit model: haiku, sonnet, or opus."
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

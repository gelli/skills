#!/bin/sh
# headroom PreToolUse hook for the Agent tool: enforces that a role (scout,
# implementer, reviewer) may only be spawned at its default model or higher,
# never lower, never fable/mythos, never "inherit", and never via
# subagent_type "fork". A role also may not be spawned with "name" set: that
# would make it an agent-teams teammate rather than a worker. Explore
# inherits the main session's model, capped at Opus, not its own. Explore,
# Plan, subagent_type empty, "general-purpose", and "claude" all need an
# explicit model. Any other named
# agent type is left to its own definition.
#
# Rank: haiku=1, sonnet=2, opus=3, classified by case-insensitive substring so
# full model IDs work too (claude-opus-5-5, us.anthropic.claude-haiku-4-5...,
# "opus[1m]"). Role defaults: scout=haiku, implementer=sonnet, reviewer=sonnet.
#
# Every allowed spawn is logged with hr_log_fields (subagent_type, role,
# model as passed or "default:<role default>", whether it was raised,
# isolation, run_in_background, whether name was set); denies keep logging
# through hr_log, as before.
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
  (.tool_input.name // ""),
  (.tool_input.isolation // "" | if type == "string" then . else tostring end),
  (if (.tool_input.run_in_background // false) then "true" else "false" end)
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
iso = t.get("isolation")
if iso is None:
    iso = ""
elif not isinstance(iso, str):
    iso = json.dumps(iso)
print(iso)
print("true" if t.get("run_in_background") else "false")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); Agent check skipped" >&2
  exit 0
fi

subagent_type=$(printf '%s\n' "$fields" | sed -n 2p)
model=$(printf '%s\n' "$fields" | sed -n 3p)
name=$(printf '%s\n' "$fields" | sed -n 4p)
isolation=$(printf '%s\n' "$fields" | sed -n 5p)
run_in_background=$(printf '%s\n' "$fields" | sed -n 6p)
model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
role=${subagent_type#headroom:}
if [ -n "$name" ]; then named=true; else named=false; fi

deny_and_log() { # reason
  hr_log deny check-agent "$1"
  hr_deny "$1"
  exit 0
}

# allow_and_log <role-for-log> <model-for-log> <raised> -- logs an allowed
# spawn with the fields Phase 2 needs (2.2), then exits allow. role and
# raised are only meaningful for scout/implementer/reviewer; every other
# subagent_type logs role "" and raised false.
allow_and_log() {
  hr_log_fields allow check-agent \
    subagent_type "$subagent_type" \
    role "$1" \
    model "$2" \
    raised "$3" \
    isolation "$isolation" \
    run_in_background "$run_in_background" \
    named "$named"
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
    if [ -z "$model" ]; then
      allow_and_log "$role" "default:$default_name" false
    fi
    rank=$(rank_of "$model_lc")
    if [ -z "$rank" ]; then
      echo "headroom: model \"$model\" for headroom:$role is not a recognised tier (haiku/sonnet/opus); allowing it through unchecked" >&2
      allow_and_log "$role" "$model" false
    fi
    if [ "$rank" -ge "$default_rank" ]; then
      if [ "$rank" -gt "$default_rank" ]; then raised=true; else raised=false; fi
      allow_and_log "$role" "$model" "$raised"
    fi
    deny_and_log "headroom: headroom:$role's default model is $default_name; roles may only be raised, never lowered. Re-issue with model omitted (uses $default_name) or raised to sonnet or opus."
    ;;
  Explore|Plan)
    # Explore actually runs on the main session's model (capped at Opus), not
    # its own, so a model-less spawn is denied (plan item 4.7).
    if [ -z "$model" ]; then
      deny_and_log "headroom: subagent_type \"$subagent_type\" without a model would run on the orchestrator model. Re-issue the call with an explicit model (haiku, sonnet, or opus), or prefer headroom:scout for search and lookup work."
    fi
    allow_and_log "" "$model" false
    ;;
  ""|general-purpose|claude)
    if [ -z "$model" ]; then
      deny_and_log "headroom: subagent_type \"$subagent_type\" has no default model, so it would inherit the orchestrator model. Re-issue the call with an explicit model: haiku, sonnet, or opus."
    fi
    allow_and_log "" "$model" false
    ;;
  *)
    allow_and_log "" "$model" false
    ;;
esac

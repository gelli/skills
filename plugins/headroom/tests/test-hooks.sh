#!/bin/sh
# Replays every headroom hook against crafted inputs on both parser paths
# (jq, python3). Run from anywhere:
#   sh plugins/headroom/tests/test-hooks.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
hooks="$root/hooks"
fail=0

check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fail=1; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ======================================================================
# lib.sh: hr_log_fields
# ======================================================================

run_hr_log_fields_matrix() { # label
  echo "$1"
  data="$tmp/lib-data"
  rm -rf "$data"
  mkdir -p "$data"
  (
    export CLAUDE_PLUGIN_DATA="$data"
    . "$hooks/lib.sh"
    HR_INPUT='{"session_id":"sess-42"}'
    hr_log_fields spawn check-agent role scout count 3 raised false leadingzero 007 empty "" name 'a "quoted" role'
  )
  line=$(cat "$data/headroom.log.jsonl" 2>/dev/null)
  case "$line" in
    *'"session_id":"sess-42"'*) echo "  ok    session_id read from HR_INPUT" ;;
    *) echo "  FAIL  session_id missing from log line: $line"; fail=1 ;;
  esac
  case "$line" in
    *'"count":3'*) echo "  ok    integer logged unquoted" ;;
    *) echo "  FAIL  integer should be unquoted: $line"; fail=1 ;;
  esac
  case "$line" in
    *'"raised":false'*) echo "  ok    boolean logged unquoted" ;;
    *) echo "  FAIL  boolean should be unquoted: $line"; fail=1 ;;
  esac
  case "$line" in
    *'"leadingzero":"007"'*) echo "  ok    leading-zero string stays quoted" ;;
    *) echo "  FAIL  leading-zero string should stay quoted: $line"; fail=1 ;;
  esac
  case "$line" in
    *'"name":"a \"quoted\" role"'*) echo "  ok    string value JSON-escaped" ;;
    *) echo "  FAIL  string value not escaped correctly: $line"; fail=1 ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$line" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      echo "  ok    log line is valid JSON"
    else
      echo "  FAIL  log line is not valid JSON: $line"; fail=1
    fi
  fi

  # No HR_INPUT (or unparseable session): session_id is still present, empty.
  rm -rf "$data"
  mkdir -p "$data"
  (
    export CLAUDE_PLUGIN_DATA="$data"
    . "$hooks/lib.sh"
    hr_log_fields deny check-agent reason "no name field this time"
  )
  line=$(cat "$data/headroom.log.jsonl" 2>/dev/null)
  case "$line" in
    *'"session_id":""'*) echo "  ok    session_id empty when HR_INPUT unset" ;;
    *) echo "  FAIL  session_id should be empty: $line"; fail=1 ;;
  esac

  # No CLAUDE_PLUGIN_DATA: best-effort no-op, never fails.
  (
    unset CLAUDE_PLUGIN_DATA
    . "$hooks/lib.sh"
    hr_log_fields spawn check-agent role scout
  )
  echo "  ok    silently does nothing without CLAUDE_PLUGIN_DATA (no crash)"
}

if command -v jq >/dev/null 2>&1; then
  run_hr_log_fields_matrix "hr_log_fields via jq"
else
  echo "jq not installed; skipping hr_log_fields jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_hr_log_fields_matrix "hr_log_fields via python3"
else
  echo "python3 not installed; skipping hr_log_fields python3 path"
fi

# ======================================================================
# check-agent.sh
# ======================================================================

agent_decision() { # json
  out=$(printf '%s' "$1" | "$hooks/check-agent.sh" 2>/dev/null)
  case "$out" in
    "") printf allow ;;
    *'"permissionDecision":"deny"'*) printf deny ;;
    *) printf other ;;
  esac
}

run_agent_matrix() { # label
  echo "$1"
  check "fork denied"                    deny  "$(agent_decision '{"tool_input":{"subagent_type":"fork","model":"sonnet"}}')"
  check "fable denied"                   deny  "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout","model":"fable"}}')"
  check "mythos denied (full id)"        deny  "$(agent_decision '{"tool_input":{"subagent_type":"headroom:reviewer","model":"claude-mythos-1"}}')"
  check "inherit denied"                 deny  "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout","model":"inherit"}}')"
  check "scout no model allowed"         allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout"}}')"
  check "scout raised to sonnet"         allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout","model":"sonnet"}}')"
  check "scout at default (haiku)"       allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout","model":"haiku"}}')"
  check "implementer at default sonnet"  allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:implementer","model":"sonnet"}}')"
  check "implementer raised to opus"     allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:implementer","model":"opus"}}')"
  check "implementer lowered to haiku"   deny  "$(agent_decision '{"tool_input":{"subagent_type":"headroom:implementer","model":"haiku"}}')"
  check "reviewer lowered to haiku"      deny  "$(agent_decision '{"tool_input":{"subagent_type":"headroom:reviewer","model":"haiku"}}')"
  check "reviewer full id opus, no prefix" allow "$(agent_decision '{"tool_input":{"subagent_type":"reviewer","model":"claude-opus-5-5"}}')"
  check "scout full id haiku"            allow "$(agent_decision '{"tool_input":{"subagent_type":"scout","model":"us.anthropic.claude-haiku-4-5-v1:0"}}')"
  check "opus 1m tag"                    allow "$(agent_decision '{"tool_input":{"subagent_type":"reviewer","model":"opus[1m]"}}')"
  check "unknown model string allowed"   allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout","model":"gpt-4"}}')"
  check "Explore allowed"                allow "$(agent_decision '{"tool_input":{"subagent_type":"Explore"}}')"
  check "Plan allowed"                   allow "$(agent_decision '{"tool_input":{"subagent_type":"Plan"}}')"
  check "general-purpose no model denied" deny "$(agent_decision '{"tool_input":{"subagent_type":"general-purpose"}}')"
  check "general-purpose with model allowed" allow "$(agent_decision '{"tool_input":{"subagent_type":"general-purpose","model":"sonnet"}}')"
  check "empty subagent_type no model denied" deny "$(agent_decision '{"tool_input":{}}')"
  check "claude no model denied"         deny  "$(agent_decision '{"tool_input":{"subagent_type":"claude"}}')"
  check "other named type allowed"       allow "$(agent_decision '{"tool_input":{"subagent_type":"browser-scout"}}')"
  check "unparseable input allowed"      allow "$(agent_decision 'not json')"
  check "empty input allowed"            allow "$(agent_decision '')"
}

if command -v jq >/dev/null 2>&1; then
  run_agent_matrix "check-agent via jq"
else
  echo "jq not installed; skipping check-agent jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_agent_matrix "check-agent via python3"
else
  echo "python3 not installed; skipping check-agent python3 path"
fi

# ======================================================================
# check-workflow.sh
# ======================================================================

workflow_decision() { # json
  out=$(printf '%s' "$1" | "$hooks/check-workflow.sh" 2>/dev/null)
  case "$out" in
    "") printf allow ;;
    *'"permissionDecision":"deny"'*) printf deny ;;
    *) printf other ;;
  esac
}

run_workflow_matrix() { # label
  echo "$1"
  check "fable in inline script"    deny  "$(workflow_decision '{"tool_input":{"script":"Agent({ model: \"fable\" })"}}')"
  check "mythos in inline script"   deny  "$(workflow_decision '{"tool_input":{"script":"Agent({ model: \"MYTHOS\" })"}}')"
  check "clean inline script"       allow "$(workflow_decision '{"tool_input":{"script":"Agent({ model: \"sonnet\" })"}}')"

  fable_path="$tmp/wf-fable.js"
  printf 'Agent({ model: "Fable" })\n' >"$fable_path"
  payload=$(printf '{"tool_input":{"scriptPath":"%s"}}' "$fable_path")
  check "fable via scriptPath"      deny  "$(workflow_decision "$payload")"

  clean_path="$tmp/wf-clean.js"
  printf 'Agent({ model: "opus" })\n' >"$clean_path"
  payload=$(printf '{"tool_input":{"scriptPath":"%s"}}' "$clean_path")
  check "clean scriptPath"          allow "$(workflow_decision "$payload")"

  check "named workflow only"       allow "$(workflow_decision '{"tool_input":{"name":"nightly-report"}}')"
  check "unparseable input allowed" allow "$(workflow_decision 'not json')"

  multiline='line one
line two
line three
line four
model: \"fable\"
line six'
  esc_multiline=$(printf '%s' "$multiline" | awk '{printf "%s\\n", $0}')
  payload=$(printf '{"tool_input":{"script":"%s"}}' "$esc_multiline")
  check "fable on line 5 of a multi-line inline script" deny "$(workflow_decision "$payload")"

  multi_path="$tmp/wf-multiline.js"
  printf 'line one\nline two\nline three\nline four\nmodel: "fable"\nline six\n' >"$multi_path"
  payload=$(printf '{"tool_input":{"scriptPath":"%s"}}' "$multi_path")
  check "fable on line 5 via scriptPath" deny "$(workflow_decision "$payload")"

  # The key and its quoted value split across two lines (e.g. a YAML-ish
  # "model:\n  \"fable\"") must still be caught: matching is per-line unless
  # newlines are flattened first.
  split_script='model:\n  \"fable\"\n'
  payload=$(printf '{"tool_input":{"script":"%s"}}' "$split_script")
  check "fable split across two lines, inline script" deny "$(workflow_decision "$payload")"

  split_path="$tmp/wf-split.js"
  printf 'model:\n  "fable"\n' >"$split_path"
  payload=$(printf '{"tool_input":{"scriptPath":"%s"}}' "$split_path")
  check "fable split across two lines, scriptPath" deny "$(workflow_decision "$payload")"
}

if command -v jq >/dev/null 2>&1; then
  run_workflow_matrix "check-workflow via jq"
else
  echo "jq not installed; skipping check-workflow jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_workflow_matrix "check-workflow via python3"
else
  echo "python3 not installed; skipping check-workflow python3 path"
fi

# ======================================================================
# block.sh
# ======================================================================

block_decision() { # json
  out=$(printf '%s' "$1" | "$hooks/block.sh" 2>/dev/null)
  case "$out" in
    "") printf allow ;;
    *'"permissionDecision":"deny"'*) printf deny ;;
    *) printf other ;;
  esac
}

run_block_matrix() { # label
  echo "$1"
  unset CLAUDE_PLUGIN_OPTION_HARD_BLOCKS CLAUDE_PLUGIN_OPTION_BLOCK_PATTERNS HEADROOM_BLOCKS

  check "disabled by default"          allow "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"}}')"

  export CLAUDE_PLUGIN_OPTION_HARD_BLOCKS=true

  check "npm test blocked"             deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  check "npm run test blocked"         deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm run test"}}')"
  check "npm run build:prod blocked"   deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm run build:prod"}}')"
  check "npm run test:ci blocked"      deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm run test:ci"}}')"
  check "yarn lint:fix blocked"        deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"yarn lint:fix"}}')"
  check "pnpm run typecheck:watch blocked" deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"pnpm run typecheck:watch"}}')"
  check "rtk prefix stripped"          deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"rtk npm test"}}')"
  check "env assignment stripped"      deny  "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"CI=true npm test"}}')"
  check "compound command (&&) blocked" deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"cd foo && pytest -q"}}')"
  multiline_cmd='cd foo
npm test'
  esc_cmd=$(printf '%s' "$multiline_cmd" | awk '{printf "%s\\n", $0}')
  payload=$(printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"%s"}}' "$esc_cmd")
  check "multi-line command blocked"    deny  "$(block_decision "$payload")"
  check "unrelated bash allowed"        allow "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls -la"}}')"

  # Heredoc body text must not be read as a command: "go test ./..." here is
  # prose inside the commit-message heredoc, not an invocation.
  heredoc_cmd='git commit -m \"$(cat <<EOF
fix: something
go test ./... now passes
EOF
)\"'
  esc_heredoc=$(printf '%s' "$heredoc_cmd" | awk '{printf "%s\\n", $0}')
  payload=$(printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"%s"}}' "$esc_heredoc")
  check "heredoc body text not read as a command" allow "$(block_decision "$payload")"

  # Same check with no quoting at all involved, so this only passes if
  # heredoc stripping itself (not quote stripping) is doing the work: an
  # unquoted heredoc whose body is a bare blocked command.
  check "unquoted heredoc body not read as a command" allow \
    "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"cat > notes.md <<EOF\nnpm test\nEOF\n"}}')"

  # Semicolons and a blocked-looking phrase inside a quoted string must not
  # be split out and matched as separate commands.
  check "quoted string not split or matched" allow "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo \"a; npm test; b\""}}')"

  # Subshells and command substitution are not segment boundaries by
  # default; $(, (, ), and backticks must be treated as boundaries too, so
  # the inner command is still caught.
  check "subshell with && blocked"      deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"(cd frontend && npm test)"}}')"
  check "bare subshell blocked"         deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"(npm test)"}}')"
  check "dollar-paren command substitution blocked" deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo $(npm test)"}}')"
  check "backtick command substitution blocked" deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo `npm test`"}}')"
  check "assignment from command substitution blocked" deny "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"RESULT=$(npm test)"}}')"

  # Parens that are only inside a quoted string are not boundaries: the
  # quote content is already dropped before subshell-boundary insertion.
  check "parens inside quoted string allowed" allow "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo \"(npm test)\""}}')"

  # strip_quotes must not toggle double-quote state on an escaped quote.
  check "escaped double quote inside string still blocks trailing command" deny \
    "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo \"\\\"\" && npm test"}}')"

  # Inside single quotes, backslash is a literal (bash semantics): nothing
  # here should be blocked.
  check "backslash literal inside single quotes allowed" allow \
    "$(block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo '\''a\\'\'' && echo b"}}')"

  check "worker call passes (agent_id)" allow "$(block_decision '{"session_id":"s1","agent_id":"a1","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  check "HEADROOM_BLOCKS=0 overrides"   allow "$(HEADROOM_BLOCKS=0 block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  check "extra block_patterns"         deny  "$(CLAUDE_PLUGIN_OPTION_BLOCK_PATTERNS='^custom-runner' block_decision '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"custom-runner suite"}}')"

  check "Grep repo-wide blocked"        deny  "$(block_decision '{"session_id":"s1","tool_name":"Grep","tool_input":{"pattern":"TODO"}}')"
  check "Grep with glob exempt"         allow "$(block_decision '{"session_id":"s1","tool_name":"Grep","tool_input":{"pattern":"TODO","glob":"*.ts"}}')"
  check "Grep with path subdir allowed" allow "$(block_decision '{"session_id":"s1","tool_name":"Grep","tool_input":{"pattern":"TODO","path":"src/lib"}}')"
  payload=$(printf '{"session_id":"s1","tool_name":"Grep","tool_input":{"pattern":"TODO","path":"%s"}}' "$CLAUDE_PROJECT_DIR")
  check "Grep path = project dir blocked" deny "$(block_decision "$payload")"

  check "Glob repo-wide allowed (never blocked)" allow "$(block_decision '{"session_id":"s1","tool_name":"Glob","tool_input":{"pattern":"**/*.ts"}}')"
  check "Glob with path subdir allowed" allow "$(block_decision '{"session_id":"s1","tool_name":"Glob","tool_input":{"pattern":"**/*.ts","path":"src"}}')"

  rm -rf "$CLAUDE_PLUGIN_DATA/inline"
  mkdir -p "$CLAUDE_PLUGIN_DATA/inline"
  printf once >"$CLAUDE_PLUGIN_DATA/inline/s-once"
  check "override once lifts the block" allow "$(block_decision '{"session_id":"s-once","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  check "override once is consumed"     deny  "$(block_decision '{"session_id":"s-once","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  printf session >"$CLAUDE_PLUGIN_DATA/inline/s-session"
  check "override session lifts the block" allow "$(block_decision '{"session_id":"s-session","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  check "override session persists"     allow "$(block_decision '{"session_id":"s-session","tool_name":"Bash","tool_input":{"command":"npm test"}}')"

  printf once >"$CLAUDE_PLUGIN_DATA/inline/s-benign"
  check "benign call does not consume once" allow "$(block_decision '{"session_id":"s-benign","tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
  check "override file survives the benign call" once "$(cat "$CLAUDE_PLUGIN_DATA/inline/s-benign" 2>/dev/null)"
  check "once still lifts the next, real, block" allow "$(block_decision '{"session_id":"s-benign","tool_name":"Bash","tool_input":{"command":"npm test"}}')"
  check "once is consumed by that block"    deny  "$(block_decision '{"session_id":"s-benign","tool_name":"Bash","tool_input":{"command":"npm test"}}')"

  check "unparseable input allowed"     allow "$(block_decision 'not json')"

  unset CLAUDE_PLUGIN_OPTION_HARD_BLOCKS CLAUDE_PLUGIN_OPTION_BLOCK_PATTERNS HEADROOM_BLOCKS
}

export CLAUDE_PLUGIN_DATA="$tmp/data"
export CLAUDE_PROJECT_DIR="$tmp/proj"
mkdir -p "$CLAUDE_PLUGIN_DATA" "$CLAUDE_PROJECT_DIR"

if command -v jq >/dev/null 2>&1; then
  run_block_matrix "block via jq"
else
  echo "jq not installed; skipping block jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_block_matrix "block via python3"
else
  echo "python3 not installed; skipping block python3 path"
fi

# ======================================================================
# inline.sh
# ======================================================================

run_inline_matrix() { # label
  echo "$1"
  data="$tmp/inline-data"
  rm -rf "$data"
  mkdir -p "$data"

  (
    export CLAUDE_PLUGIN_DATA="$data"
    printf '%s' '{"session_id":"once1","prompt":"/headroom:inline"}' | "$hooks/inline.sh"
  ) >/dev/null 2>&1
  check "writes once"   once "$(cat "$data/inline/once1" 2>/dev/null)"

  (
    export CLAUDE_PLUGIN_DATA="$data"
    printf '%s' '{"session_id":"sess1","prompt":"/headroom:inline session"}' | "$hooks/inline.sh"
  ) >/dev/null 2>&1
  check "writes session" session "$(cat "$data/inline/sess1" 2>/dev/null)"

  (
    export CLAUDE_PLUGIN_DATA="$data"
    printf '%s' '{"session_id":"sess1","prompt":"hello there"}' | "$hooks/inline.sh"
  ) >/dev/null 2>&1
  check "other prompt is a no-op" session "$(cat "$data/inline/sess1" 2>/dev/null)"
}

if command -v jq >/dev/null 2>&1; then
  run_inline_matrix "inline via jq"
else
  echo "jq not installed; skipping inline jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_inline_matrix "inline via python3"
else
  echo "python3 not installed; skipping inline python3 path"
fi

# ======================================================================
# nudge.sh
# ======================================================================

run_nudge_matrix() { # label
  echo "$1"
  big=$(awk 'BEGIN{s=""; for(i=0;i<40000;i++) s=s "x"; print s}')
  out=$(printf '{"tool_name":"Bash","tool_response":{"stdout":"%s"}}' "$big" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  ok    over-threshold nudges" ;;
    *) echo "  FAIL  over-threshold nudge missing"; fail=1 ;;
  esac
  check "under-threshold silent" "" "$(printf '{"tool_name":"Bash","tool_response":{"stdout":"short"}}' | "$hooks/nudge.sh" 2>/dev/null)"
  check "worker call skipped" "" "$(printf '{"agent_id":"a1","tool_name":"Bash","tool_response":{"stdout":"%s"}}' "$big" | "$hooks/nudge.sh" 2>/dev/null)"
  check "unparseable input silent" "" "$(printf 'not json' | "$hooks/nudge.sh" 2>/dev/null)"

  # "é" is 2 raw UTF-8 bytes but, wrongly \u-escaped (ensure_ascii=True),
  # becomes the 6 ASCII chars "é". 6000 repeats is ~12k raw bytes
  # (under the 32768 threshold, matching jq) but ~36k mis-escaped bytes
  # (would wrongly cross it) -- this is the regression check for finding 6.
  nonascii=$(awk 'BEGIN{s=""; for(i=0;i<6000;i++) s=s "é"; print s}')
  out=$(printf '{"tool_name":"Bash","tool_response":{"stdout":"%s"}}' "$nonascii" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  FAIL  non-ASCII payload wrongly nudges (over-counted bytes)"; fail=1 ;;
    *) echo "  ok    non-ASCII payload counted as raw UTF-8 bytes, no false nudge" ;;
  esac

  nonascii_big=$(awk 'BEGIN{s=""; for(i=0;i<20000;i++) s=s "é"; print s}')
  out=$(printf '{"tool_name":"Bash","tool_response":{"stdout":"%s"}}' "$nonascii_big" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  ok    large non-ASCII payload still nudges" ;;
    *) echo "  FAIL  large non-ASCII payload should nudge"; fail=1 ;;
  esac
}

if command -v jq >/dev/null 2>&1; then
  run_nudge_matrix "nudge via jq"
else
  echo "jq not installed; skipping nudge jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_nudge_matrix "nudge via python3"
else
  echo "python3 not installed; skipping nudge python3 path"
fi

# ======================================================================
# report-warning.sh
# ======================================================================

run_report_matrix() { # label
  echo "$1"
  long_msg=$(awk 'BEGIN{for(i=0;i<70;i++) print "line " i}')
  esc_long=$(printf '%s' "$long_msg" | awk '{printf "%s\\n", $0}')

  out=$(printf '{"agent_type":"headroom:scout","last_assistant_message":"%s"}' "$esc_long" | "$hooks/report-warning.sh" 2>/dev/null)
  case "$out" in
    *'"decision":"block"'*) echo "  ok    over-line-limit blocks the worker from stopping" ;;
    *) echo "  FAIL  over-line-limit block missing"; fail=1 ;;
  esac
  case "$out" in
    *additionalContext*) echo "  FAIL  over-limit output should be a top-level decision:block, not hookSpecificOutput.additionalContext"; fail=1 ;;
    *) : ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      echo "  ok    over-limit output is valid JSON"
    else
      echo "  FAIL  over-limit output is not valid JSON: $out"; fail=1
    fi
  fi

  short_msg="line1
line2
line3"
  esc_short=$(printf '%s' "$short_msg" | awk '{printf "%s\\n", $0}')
  check "under limits silent" "" "$(printf '{"agent_type":"headroom:scout","last_assistant_message":"%s"}' "$esc_short" | "$hooks/report-warning.sh" 2>/dev/null)"

  check "stop_hook_active true stays silent even over limit" "" "$(printf '{"agent_type":"headroom:scout","stop_hook_active":true,"last_assistant_message":"%s"}' "$esc_long" | "$hooks/report-warning.sh" 2>/dev/null)"
  check "empty agent_type stays silent even over limit" "" "$(printf '{"agent_type":"","last_assistant_message":"%s"}' "$esc_long" | "$hooks/report-warning.sh" 2>/dev/null)"
  check "unparseable input silent" "" "$(printf 'not json' | "$hooks/report-warning.sh" 2>/dev/null)"
}

if command -v jq >/dev/null 2>&1; then
  run_report_matrix "report-warning via jq"
else
  echo "jq not installed; skipping report-warning jq path"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_report_matrix "report-warning via python3"
else
  echo "python3 not installed; skipping report-warning python3 path"
fi

# ======================================================================
# inject-rules.sh
# ======================================================================

echo "injector"
fake_root="$tmp/fake-root"
mkdir -p "$fake_root"
cat >"$fake_root/rules.md" <<'EOF'
# fake rules
Delegate big things.
EOF
out=$(CLAUDE_PLUGIN_ROOT="$fake_root" "$hooks/inject-rules.sh" </dev/null)
case "$out" in
  "<headroom>"*"</headroom>") echo "  ok    wrapped in <headroom> tags" ;;
  *) echo "  FAIL  tag wrapping"; fail=1 ;;
esac
case "$out" in
  *"fake rules"*) echo "  ok    contains rules.md content" ;;
  *) echo "  FAIL  rules.md content missing"; fail=1 ;;
esac
check "missing root prints nothing" "" "$(CLAUDE_PLUGIN_ROOT=/nonexistent "$hooks/inject-rules.sh" </dev/null)"

real_rules="$root/rules.md"
if [ -r "$real_rules" ]; then
  out=$(CLAUDE_PLUGIN_ROOT="$root" "$hooks/inject-rules.sh" </dev/null)
  case "$out" in
    "<headroom>"*"</headroom>") echo "  ok    real rules.md wraps cleanly" ;;
    *) echo "  FAIL  real rules.md wrapping"; fail=1 ;;
  esac
else
  echo "  skip  rules.md not present yet (written by the other worker)"
fi

[ $fail -eq 0 ] && echo "all hook tests passed" || { echo "hook tests FAILED"; exit 1; }

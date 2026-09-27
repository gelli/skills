#!/bin/sh
# Replays every headroom hook against crafted inputs on both parser paths
# (jq, python3). Run from anywhere:
#   sh plugins/headroom/tests/test-hooks.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
hooks="$root/hooks"
scripts="$root/scripts"
fail=0

check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fail=1; fi
}

# assert_parser <label> -- guard against a real regression: a prefix
# assignment on a shell *function* call (e.g. `HEADROOM_PARSER=python3
# run_x_matrix ...`) has shell-dependent persistence after the call
# returns. POSIX leaves this unspecified, and on macOS's /bin/sh (bash
# 3.2 running in POSIX mode) the assignment leaks into every command for
# the rest of the script, so a later "via jq" run would silently run on
# python3 (proven empirically; dash and non-POSIX bash do not leak this,
# so a Linux CI running either would not have hit this gap). Every
# run_*_matrix below calls this as its first statement so
# the check happens inside the run, not just around the call site, and
# would catch that regression even if a future edit reintroduced the
# leaky prefix-assignment pattern at a call site.
assert_parser() {
  case "$1" in
    *' via jq')
      if [ "${HEADROOM_PARSER:-}" = python3 ]; then
        echo "  FAIL  $1: HEADROOM_PARSER is python3, not jq (leaked?)"; fail=1
      elif ! command -v jq >/dev/null 2>&1; then
        echo "  FAIL  $1: jq is not even installed"; fail=1
      fi
      ;;
    *' via python3')
      if [ "${HEADROOM_PARSER:-}" != python3 ]; then
        echo "  FAIL  $1: HEADROOM_PARSER is '${HEADROOM_PARSER:-<unset>}', not python3"; fail=1
      fi
      ;;
  esac
}

# run_parser_matrix <matrix-func> <label-prefix> -- runs <matrix-func> once
# per available parser, with HEADROOM_PARSER set/unset as its own statement
# (never as a prefix assignment on the function call itself; see
# assert_parser above for why that matters).
run_parser_matrix() {
  matrix_func=$1
  label_prefix=$2
  if command -v jq >/dev/null 2>&1; then
    unset HEADROOM_PARSER
    "$matrix_func" "$label_prefix via jq"
  else
    echo "jq not installed; skipping $label_prefix jq path"
  fi
  if command -v python3 >/dev/null 2>&1; then
    export HEADROOM_PARSER=python3
    "$matrix_func" "$label_prefix via python3"
    unset HEADROOM_PARSER
  else
    echo "python3 not installed; skipping $label_prefix python3 path"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ======================================================================
# lib.sh: hr_log_fields
# ======================================================================

run_hr_log_fields_matrix() { # label
  echo "$1"
  assert_parser "$1"
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

  # Log rotation (Phase 2 risk: "the log grows without limit"). Reassigning
  # HR_LOG_MAX_BYTES after sourcing lib.sh tests rotation against a few
  # bytes instead of writing a real 10MB fixture.
  data_rot="$tmp/lib-rotate-data"
  rm -rf "$data_rot"
  mkdir -p "$data_rot"
  printf 'old line already past the tiny test cap\n' >"$data_rot/headroom.log.jsonl"
  (
    export CLAUDE_PLUGIN_DATA="$data_rot"
    . "$hooks/lib.sh"
    HR_LOG_MAX_BYTES=10
    hr_log_fields spawn check-agent role scout
  )
  case "$(cat "$data_rot/headroom.log.jsonl.1" 2>/dev/null)" in
    *"old line already past the tiny test cap"*)
      echo "  ok    a log at or over the cap is rotated to .1 before the new line is appended" ;;
    *) echo "  FAIL  old log content missing from .1 after rotation"; fail=1 ;;
  esac
  new_content=$(cat "$data_rot/headroom.log.jsonl" 2>/dev/null)
  case "$new_content" in
    *"old line already past the tiny test cap"*)
      echo "  FAIL  rotated content leaked into the new file: $new_content"; fail=1 ;;
    *'"event":"spawn"'*) echo "  ok    the new file after rotation holds only the new line" ;;
    *) echo "  FAIL  new line missing after rotation: $new_content"; fail=1 ;;
  esac

  # Under the cap: no rotation, the file just grows.
  data_norot="$tmp/lib-norotate-data"
  rm -rf "$data_norot"
  mkdir -p "$data_norot"
  printf 'short\n' >"$data_norot/headroom.log.jsonl"
  (
    export CLAUDE_PLUGIN_DATA="$data_norot"
    . "$hooks/lib.sh"
    HR_LOG_MAX_BYTES=10000000
    hr_log_fields spawn check-agent role scout
  )
  check "no rotation file created when under the cap" "" "$(cat "$data_norot/headroom.log.jsonl.1" 2>/dev/null)"
  case "$(cat "$data_norot/headroom.log.jsonl" 2>/dev/null)" in
    *short*'"event":"spawn"'*) echo "  ok    file grows normally under the cap" ;;
    *) echo "  FAIL  file did not grow normally under the cap"; fail=1 ;;
  esac

  # hr_log rotates too, not only hr_log_fields.
  data_rot2="$tmp/lib-rotate-data-2"
  rm -rf "$data_rot2"
  mkdir -p "$data_rot2"
  printf 'old detail line past cap\n' >"$data_rot2/headroom.log.jsonl"
  (
    export CLAUDE_PLUGIN_DATA="$data_rot2"
    . "$hooks/lib.sh"
    HR_LOG_MAX_BYTES=5
    hr_log override block "new detail"
  )
  case "$(cat "$data_rot2/headroom.log.jsonl.1" 2>/dev/null)" in
    *"old detail line past cap"*) echo "  ok    hr_log rotates too, not only hr_log_fields" ;;
    *) echo "  FAIL  hr_log did not rotate"; fail=1 ;;
  esac
}

run_parser_matrix run_hr_log_fields_matrix "hr_log_fields"

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
  assert_parser "$1"
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
  check "reviewer with name denied"        deny  "$(agent_decision '{"tool_input":{"subagent_type":"headroom:reviewer","model":"opus","name":"casey"}}')"
  check "reviewer without name allowed"    allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:reviewer","model":"opus"}}')"
  check "scout full id haiku"            allow "$(agent_decision '{"tool_input":{"subagent_type":"scout","model":"us.anthropic.claude-haiku-4-5-v1:0"}}')"
  check "opus 1m tag"                    allow "$(agent_decision '{"tool_input":{"subagent_type":"reviewer","model":"opus[1m]"}}')"
  check "unknown model string allowed"   allow "$(agent_decision '{"tool_input":{"subagent_type":"headroom:scout","model":"gpt-4"}}')"
  check "Explore allowed"                allow "$(agent_decision '{"tool_input":{"subagent_type":"Explore"}}')"
  check "Plan allowed"                   allow "$(agent_decision '{"tool_input":{"subagent_type":"Plan"}}')"
  check "general-purpose no model denied" deny "$(agent_decision '{"tool_input":{"subagent_type":"general-purpose"}}')"
  check "general-purpose with model allowed" allow "$(agent_decision '{"tool_input":{"subagent_type":"general-purpose","model":"sonnet"}}')"
  check "general-purpose with name and model unaffected" allow "$(agent_decision '{"tool_input":{"subagent_type":"general-purpose","model":"sonnet","name":"casey"}}')"
  check "empty subagent_type no model denied" deny "$(agent_decision '{"tool_input":{}}')"
  check "claude no model denied"         deny  "$(agent_decision '{"tool_input":{"subagent_type":"claude"}}')"
  check "other named type allowed"       allow "$(agent_decision '{"tool_input":{"subagent_type":"browser-scout"}}')"
  check "unparseable input allowed"      allow "$(agent_decision 'not json')"
  check "empty input allowed"            allow "$(agent_decision '')"
}

run_parser_matrix run_agent_matrix "check-agent"

# check-agent.sh: allowed spawns are logged (2.2). Denies were already
# covered by the log-based tests above via hr_log; this checks the new
# hr_log_fields line for an allow.
run_agent_log_matrix() { # label
  echo "$1"
  assert_parser "$1"
  data="$tmp/agent-log-data"
  rm -rf "$data"
  mkdir -p "$data"
  (
    export CLAUDE_PLUGIN_DATA="$data"
    printf '%s' '{"session_id":"s1","tool_input":{"subagent_type":"headroom:scout"}}' | "$hooks/check-agent.sh" >/dev/null 2>&1
    printf '%s' '{"session_id":"s1","tool_input":{"subagent_type":"headroom:scout","model":"sonnet"}}' | "$hooks/check-agent.sh" >/dev/null 2>&1
  )
  lines=$(cat "$data/headroom.log.jsonl" 2>/dev/null)
  first=$(printf '%s\n' "$lines" | sed -n 1p)
  second=$(printf '%s\n' "$lines" | sed -n 2p)
  if command -v python3 >/dev/null 2>&1; then
    ok=$(printf '%s' "$first" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); sys.exit()
print("yes" if (
    d.get("event") == "allow" and d.get("hook") == "check-agent" and
    d.get("session_id") == "s1" and d.get("subagent_type") == "headroom:scout" and
    d.get("role") == "scout" and d.get("model") == "default:haiku" and
    d.get("raised") is False and d.get("run_in_background") is False
) else "no")
')
    check "allowed spawn logs a line, model default, not raised" yes "$ok"
    ok2=$(printf '%s' "$second" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); sys.exit()
print("yes" if d.get("raised") is True and d.get("model") == "sonnet" else "no")
')
    check "raised spawn logs raised true" yes "$ok2"
  else
    case "$first" in
      *'"event":"allow"'*'"hook":"check-agent"'*) echo "  ok    allowed spawn logs a line" ;;
      *) echo "  FAIL  allowed spawn did not log: $first"; fail=1 ;;
    esac
  fi
}

run_parser_matrix run_agent_log_matrix "check-agent allow logging"

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
  assert_parser "$1"
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

run_parser_matrix run_workflow_matrix "check-workflow"

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

# block_reason: the raw hook output, for tests that need the deny message
# text rather than just the allow/deny classification.
block_reason() { # json
  printf '%s' "$1" | "$hooks/block.sh" 2>/dev/null
}

# delegate_wording: does a deny message tell the model to delegate to
# headroom:scout? Built-in matches must say yes; block_patterns matches
# must say no (plan 1.4).
delegate_wording() { # deny output
  case "$1" in
    *deleg*|*scout*) printf yes ;;
    *) printf no ;;
  esac
}

run_block_matrix() { # label
  echo "$1"
  assert_parser "$1"
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

  # A block_patterns match is a user's own rule, not necessarily delegable
  # test/build work, so its deny message must stay neutral: no "delegate"
  # wording, but it names block_patterns and points at /headroom:inline. A
  # built-in match keeps today's delegate-to-scout message.
  custom_reason=$(CLAUDE_PLUGIN_OPTION_BLOCK_PATTERNS='^custom-runner' block_reason '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"custom-runner suite"}}')
  check "block_patterns match has no delegate wording" no "$(delegate_wording "$custom_reason")"
  case "$custom_reason" in
    *block_patterns*'/headroom:inline'*) neutral_ok=yes ;;
    *) neutral_ok=no ;;
  esac
  check "block_patterns match names the pattern and /headroom:inline" yes "$neutral_ok"
  builtin_reason=$(block_reason '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"}}')
  check "built-in match keeps delegate wording" yes "$(delegate_wording "$builtin_reason")"

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

  # A block log line carries session_id and a byte size (plan 2.4), not just
  # a detail string. tail -n 1: the log accumulates across every check
  # above and every parser-matrix pass, so only the most recent line is
  # this call's.
  block_decision '{"session_id":"s-log","tool_name":"Bash","tool_input":{"command":"npm test"}}' >/dev/null
  block_log_line=$(tail -n 1 "$CLAUDE_PLUGIN_DATA/headroom.log.jsonl" 2>/dev/null)
  case "$block_log_line" in
    *'"event":"block"'*'"session_id":"s-log"'*'"tool_name":"Bash"'*'"bytes":8'*)
      echo "  ok    block log line carries session_id, tool_name, and byte size" ;;
    *) echo "  FAIL  block log line missing session_id/tool_name/bytes: $block_log_line"; fail=1 ;;
  esac

  block_decision '{"session_id":"s-log2","tool_name":"Grep","tool_input":{"pattern":"TODO"}}' >/dev/null
  grep_log_line=$(tail -n 1 "$CLAUDE_PLUGIN_DATA/headroom.log.jsonl" 2>/dev/null)
  case "$grep_log_line" in
    *'"event":"block"'*'"session_id":"s-log2"'*'"tool_name":"Grep"'*'"bytes":0'*)
      echo "  ok    Grep block log line has byte size 0 (no command field)" ;;
    *) echo "  FAIL  Grep block log line wrong: $grep_log_line"; fail=1 ;;
  esac

  unset CLAUDE_PLUGIN_OPTION_HARD_BLOCKS CLAUDE_PLUGIN_OPTION_BLOCK_PATTERNS HEADROOM_BLOCKS
}

export CLAUDE_PLUGIN_DATA="$tmp/data"
export CLAUDE_PROJECT_DIR="$tmp/proj"
mkdir -p "$CLAUDE_PLUGIN_DATA" "$CLAUDE_PROJECT_DIR"

run_parser_matrix run_block_matrix "block"

# ======================================================================
# inline.sh
# ======================================================================

run_inline_matrix() { # label
  echo "$1"
  assert_parser "$1"
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

run_parser_matrix run_inline_matrix "inline"

# ======================================================================
# nudge.sh
# ======================================================================

run_nudge_matrix() { # label
  echo "$1"
  assert_parser "$1"
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

  # 1.5: the widened matcher includes mcp__.* (and WebSearch); an
  # over-threshold response from an MCP tool still nudges.
  out=$(printf '{"tool_name":"mcp__plugin_context7_context7__query-docs","tool_response":{"result":"%s"}}' "$big" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  ok    over-threshold mcp__ response nudges (1.5)" ;;
    *) echo "  FAIL  over-threshold mcp__ response should nudge"; fail=1 ;;
  esac

  # 1.9 / C3: a persistedOutputPath means the model only saw a ~2KB preview,
  # so the full stdout+stderr never entered the main context. The pair below
  # uses the same 30,000-char stdout (jq's cap) plus 5,000 of stderr, over
  # threshold on byte count alone, so persistedOutputPath is the only thing
  # that can explain the difference between the two outcomes.
  stdout30k=$(awk 'BEGIN{s=""; for(i=0;i<30000;i++) s=s "x"; print s}')
  stderr5k=$(awk 'BEGIN{s=""; for(i=0;i<5000;i++) s=s "y"; print s}')
  check "Bash with persistedOutputPath stays silent (1.9)" "" \
    "$(printf '{"tool_name":"Bash","tool_response":{"stdout":"%s","stderr":"%s","persistedOutputPath":"/tmp/out"}}' "$stdout30k" "$stderr5k" | "$hooks/nudge.sh" 2>/dev/null)"
  out=$(printf '{"tool_name":"Bash","tool_response":{"stdout":"%s","stderr":"%s"}}' "$stdout30k" "$stderr5k" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  ok    same stdout+stderr without persistedOutputPath nudges (1.9)" ;;
    *) echo "  FAIL  Bash with no persistedOutputPath should nudge"; fail=1 ;;
  esac

  # 1.9: Read is measured by file.content, not the whole tool_response.
  content40k=$(awk 'BEGIN{s=""; for(i=0;i<40000;i++) s=s "z"; print s}')
  out=$(printf '{"tool_name":"Read","tool_response":{"file":{"content":"%s","numLines":1}}}' "$content40k" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  ok    Read with 40KB content nudges (1.9)" ;;
    *) echo "  FAIL  Read with 40KB content should nudge"; fail=1 ;;
  esac
  check "Read with small content stays silent (1.9)" "" \
    "$(printf '{"tool_name":"Read","tool_response":{"file":{"content":"short"}}}' | "$hooks/nudge.sh" 2>/dev/null)"

  # Regression check for finding 6 still applies to the tojson branch (any
  # non-Bash, non-Read tool, e.g. WebFetch): the same non-ASCII payload used
  # above, wrapped in a JSON object, must not wrongly cross the threshold
  # because of ensure_ascii mis-escaping.
  out=$(printf '{"tool_name":"WebFetch","tool_response":{"body":"%s"}}' "$nonascii" | "$hooks/nudge.sh" 2>/dev/null)
  case "$out" in
    *additionalContext*) echo "  FAIL  non-ASCII WebFetch payload wrongly nudges (over-counted bytes)"; fail=1 ;;
    *) echo "  ok    non-ASCII WebFetch payload (tojson branch) counted correctly, no false nudge" ;;
  esac

  # 2.4: every nudge log line records tool_name and the measured byte count
  # as structured fields.
  data="$tmp/nudge-log-data"
  rm -rf "$data"
  mkdir -p "$data"
  (
    export CLAUDE_PLUGIN_DATA="$data"
    printf '{"session_id":"n1","tool_name":"Bash","tool_response":{"stdout":"%s"}}' "$big" | "$hooks/nudge.sh" >/dev/null 2>&1
  )
  log=$(cat "$data/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"event":"nudge"'*'"hook":"nudge"'*'"session_id":"n1"'*'"tool_name":"Bash"'*'"bytes":40000'*)
      echo "  ok    nudge log line has structured tool_name and bytes fields (2.4)" ;;
    *) echo "  FAIL  nudge log line missing structured fields: $log"; fail=1 ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$log" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      echo "  ok    nudge log line is valid JSON"
    else
      echo "  FAIL  nudge log line is not valid JSON: $log"; fail=1
    fi
  fi
}

run_parser_matrix run_nudge_matrix "nudge"

# ======================================================================
# report-warning.sh
# ======================================================================

run_report_matrix() { # label
  echo "$1"
  assert_parser "$1"
  long_msg=$(awk 'BEGIN{for(i=0;i<70;i++) print "line " i}')
  esc_long=$(printf '%s' "$long_msg" | awk '{printf "%s\\n", $0}')

  # 1.1: the report-length block is headroom's own guardrail. A non-headroom
  # agent_type gets a 70-line report through silently, whatever plugin it
  # came from.
  check "Explore 70-line report stays silent (1.1)" "" "$(printf '{"agent_type":"Explore","last_assistant_message":"%s"}' "$esc_long" | "$hooks/report-warning.sh" 2>/dev/null)"
  check "superpowers:code-reviewer 70-line report stays silent (1.1)" "" "$(printf '{"agent_type":"superpowers:code-reviewer","last_assistant_message":"%s"}' "$esc_long" | "$hooks/report-warning.sh" 2>/dev/null)"

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

  # 2.1: usage logging fires on every SubagentStop, with token stats read
  # from the worker's own transcript. Fixture: two lines share message.id
  # "msg_1" (a repeated content-block line) with different usage, one line
  # is not JSON at all, and "msg_2" is a distinct turn. Counting msg_1 once,
  # with its last usage, gives turns=2, input=17, output=23, cache_read=150,
  # cache_creation=9, model claude-sonnet-5 (the last one seen). msg_2 also
  # carries the final text, equal to the input's last_assistant_message, so
  # the final-entry wait sees it at once and logs complete:true.
  data="$tmp/report-warning-data"
  fixture="$tmp/report-warning-fixture.jsonl"
  cat >"$fixture" <<'JSONL'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"id":"msg_1","model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_1","model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}
not even json
{"type":"assistant","message":{"id":"msg_2","model":"claude-sonnet-5","content":[{"type":"text","text":"short report"}],"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":50,"cache_creation_input_tokens":9}}}
JSONL

  rm -rf "$data"
  mkdir -p "$data"
  input=$(printf '{"agent_type":"headroom:scout","agent_id":"agent-xyz","agent_transcript_path":"%s","last_assistant_message":"short report"}' "$fixture")
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data" "$hooks/report-warning.sh" 2>/dev/null)
  check "usage log fixture: silent (short report, under limits)" "" "$out"
  log=$(cat "$data/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"event":"usage"'*'"agent_type":"headroom:scout"'*'"agent_id":"agent-xyz"'*'"model":"claude-sonnet-5"'*'"turns":2'*'"input_tokens":17'*'"output_tokens":23'*'"cache_read_input_tokens":150'*'"cache_creation_input_tokens":9'*'"report_bytes":12'*'"report_lines":1'*'"transcript":"ok"'*'"complete":true'*)
      echo "  ok    usage log line has deduped, summed transcript stats and the report's size" ;;
    *) echo "  FAIL  usage log line missing or wrong: $log"; fail=1 ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$log" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      echo "  ok    usage log line is valid JSON"
    else
      echo "  FAIL  usage log line is not valid JSON: $log"; fail=1
    fi
  fi

  # A worker transcript whose last entry is "<synthetic>" (Claude Code's
  # model for entries like "No response requested." or "API Error:
  # Connection lost...", always with all-zero usage) must not be counted as
  # a turn or overwrite the real last model: same fixture as above, plus one
  # trailing synthetic entry. turns/sums stay 2/17/23/150/9 and model stays
  # claude-sonnet-5, not "<synthetic>".
  fixture_synth="$tmp/report-warning-fixture-synthetic.jsonl"
  cat "$fixture" >"$fixture_synth"
  echo '{"type":"assistant","message":{"id":"msg_synth","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' >>"$fixture_synth"
  data_synth="$tmp/report-warning-data-synthetic"
  rm -rf "$data_synth"
  mkdir -p "$data_synth"
  input=$(printf '{"agent_type":"headroom:scout","agent_id":"agent-synth","agent_transcript_path":"%s","last_assistant_message":"short report"}' "$fixture_synth")
  printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data_synth" "$hooks/report-warning.sh" >/dev/null 2>&1
  log_synth=$(cat "$data_synth/headroom.log.jsonl" 2>/dev/null)
  case "$log_synth" in
    *'"model":"claude-sonnet-5"'*'"turns":2'*'"input_tokens":17'*'"output_tokens":23'*'"cache_read_input_tokens":150'*'"cache_creation_input_tokens":9'*)
      echo "  ok    a trailing <synthetic> entry is not counted as a turn and does not overwrite the real model" ;;
    *) echo "  FAIL  <synthetic> entry corrupted model/turns/sums: $log_synth"; fail=1 ;;
  esac

  # 2.1: logging is not limited to headroom roles; a non-headroom agent_type
  # with a missing transcript still gets a log line, with zero counts, and
  # is never blocked.
  data_missing="$tmp/report-warning-data-missing"
  rm -rf "$data_missing"
  mkdir -p "$data_missing"
  input=$(printf '{"agent_type":"Explore","agent_id":"agent-abc","agent_transcript_path":"/nonexistent-transcript-xyz.jsonl","last_assistant_message":"hi"}')
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data_missing" "$hooks/report-warning.sh" 2>/dev/null)
  check "Explore with a missing transcript still never blocks" "" "$out"
  log=$(cat "$data_missing/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"agent_type":"Explore"'*'"turns":0'*'"input_tokens":0'*'"transcript":"missing"'*'"complete":false'*)
      echo "  ok    missing transcript logs zero counts, not a crash" ;;
    *) echo "  FAIL  missing-transcript log line wrong: $log"; fail=1 ;;
  esac

  # 2.1: log once per stop, even when the block fires.
  data_block="$tmp/report-warning-data-block"
  rm -rf "$data_block"
  mkdir -p "$data_block"
  out=$(printf '{"agent_type":"headroom:scout","last_assistant_message":"%s"}' "$esc_long" | CLAUDE_PLUGIN_DATA="$data_block" "$hooks/report-warning.sh" 2>/dev/null)
  case "$out" in
    *'"decision":"block"'*) : ;;
    *) echo "  FAIL  expected a block with CLAUDE_PLUGIN_DATA set: $out"; fail=1 ;;
  esac
  count=$(grep -c '"event":"usage"' "$data_block/headroom.log.jsonl" 2>/dev/null)
  check "usage logged exactly once even when the block fires" "1" "$count"

  # Race with Claude Code's transcript writes: SubagentStop can fire before
  # the worker's final entry is in its transcript. Start the hook on the
  # fixture minus msg_2 and append msg_2 about 300 ms later, as observed in
  # real sessions: the hook must wait for it and log the full numbers.
  data_race="$tmp/report-warning-data-race"
  fixture_race="$tmp/report-warning-fixture-race.jsonl"
  rm -rf "$data_race"
  mkdir -p "$data_race"
  grep -v '"msg_2"' "$fixture" >"$fixture_race"
  input=$(printf '{"agent_type":"headroom:scout","agent_id":"agent-race","agent_transcript_path":"%s","last_assistant_message":"short report"}' "$fixture_race")
  ( sleep 0.3; grep '"msg_2"' "$fixture" >>"$fixture_race" ) &
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data_race" "$hooks/report-warning.sh" 2>/dev/null)
  rc=$?
  wait
  check "late final entry: silent, exit 0" "0:" "$rc:$out"
  log=$(cat "$data_race/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"turns":2'*'"input_tokens":17'*'"output_tokens":23'*'"cache_read_input_tokens":150'*'"cache_creation_input_tokens":9'*'"complete":true'*)
      echo "  ok    waits for a final entry written after the hook started" ;;
    *) echo "  FAIL  late final entry missed: $log"; fail=1 ;;
  esac

  # Giving up: the final entry never arrives within the wait. The line is
  # still logged, with the stale counts and complete:false, never a block.
  data_stale="$tmp/report-warning-data-stale"
  rm -rf "$data_stale"
  mkdir -p "$data_stale"
  grep -v '"msg_2"' "$fixture" >"$fixture_race"
  input=$(printf '{"agent_type":"headroom:scout","agent_id":"agent-stale","agent_transcript_path":"%s","last_assistant_message":"short report"}' "$fixture_race")
  out=$(printf '%s' "$input" | HEADROOM_WAIT_TRIES=1 CLAUDE_PLUGIN_DATA="$data_stale" "$hooks/report-warning.sh" 2>/dev/null)
  rc=$?
  check "final entry never written: silent, exit 0" "0:" "$rc:$out"
  log=$(cat "$data_stale/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"turns":1'*'"input_tokens":10'*'"output_tokens":20'*'"complete":false'*)
      echo "  ok    gives up and logs the stale counts flagged complete:false" ;;
    *) echo "  FAIL  timed-out wait logged wrong: $log"; fail=1 ;;
  esac

  # Ordering guard: an earlier text entry equal to the message, followed by
  # a user entry (here a stop-hook block reason), is not the final entry.
  data_order="$tmp/report-warning-data-order"
  rm -rf "$data_order"
  mkdir -p "$data_order"
  {
    cat "$fixture"
    echo '{"type":"user","message":{"role":"user","content":"shorten it"}}'
  } >"$fixture_race"
  input=$(printf '{"agent_type":"headroom:scout","agent_id":"agent-order","agent_transcript_path":"%s","last_assistant_message":"short report"}' "$fixture_race")
  printf '%s' "$input" | HEADROOM_WAIT_TRIES=1 CLAUDE_PLUGIN_DATA="$data_order" "$hooks/report-warning.sh" >/dev/null 2>&1
  case "$(cat "$data_order/headroom.log.jsonl" 2>/dev/null)" in
    *'"complete":false'*) echo "  ok    matching text followed by a user entry is not taken as the final entry" ;;
    *) echo "  FAIL  ordering guard: $(cat "$data_order/headroom.log.jsonl" 2>/dev/null)"; fail=1 ;;
  esac
}

run_parser_matrix run_report_matrix "report-warning"

# ======================================================================
# context-size.sh
# ======================================================================

run_context_size_matrix() { # label
  echo "$1"
  assert_parser "$1"
  data="$tmp/context-size-data"
  rm -rf "$data"
  mkdir -p "$data"

  # 2.3, fixture A: the tail holds a real assistant-with-usage entry
  # followed by a trailing non-assistant line. context_tokens sums input +
  # cache_read + cache_creation (not output_tokens, which isn't part of
  # what the next prompt re-sends) from that entry, and model is its model.
  fixture_a="$tmp/context-size-fixture-a.jsonl"
  cat >"$fixture_a" <<'JSONL'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":50}}}
{"type":"user","message":{"role":"user","content":"trailing, not assistant"}}
JSONL
  # No last_assistant_message: nothing to wait for, so no wait, and the
  # line says complete:false.
  input=$(printf '{"transcript_path":"%s"}' "$fixture_a")
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data" "$hooks/context-size.sh" 2>/dev/null)
  check "never prints to the model (fixture A)" "" "$out"
  log=$(cat "$data/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"event":"context"'*'"hook":"context-size"'*'"model":"claude-sonnet-5"'*'"context_tokens":650'*'"complete":false'*)
      echo "  ok    context log line sums input + cache_read + cache_creation, right model" ;;
    *) echo "  FAIL  context log line missing or wrong: $log"; fail=1 ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$log" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      echo "  ok    context log line is valid JSON"
    else
      echo "  FAIL  context log line is not valid JSON: $log"; fail=1
    fi
  fi

  # 2.3, fixture B: proves the hook reads only the tail. A usable
  # assistant-with-usage entry sits at the very top of the file, followed by
  # 250 non-assistant lines -- more than the 200-line tail window -- so
  # nothing usable remains in the last 200 lines. A future regression that
  # parses the whole file would wrongly find and log the top entry; reading
  # only the tail must stay silent instead.
  data_b="$tmp/context-size-data-b"
  rm -rf "$data_b"
  mkdir -p "$data_b"
  fixture_b="$tmp/context-size-fixture-b.jsonl"
  {
    echo '{"type":"assistant","message":{"id":"msg_top","model":"claude-opus-5-5","usage":{"input_tokens":9999,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    i=0
    while [ $i -lt 250 ]; do
      echo '{"type":"user","message":{"role":"user","content":"filler"}}'
      i=$((i + 1))
    done
  } >"$fixture_b"
  input=$(printf '{"transcript_path":"%s"}' "$fixture_b")
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data_b" "$hooks/context-size.sh" 2>/dev/null)
  check "never prints to the model (fixture B)" "" "$out"
  check "tail-only read: entry outside the last 200 lines is never logged" "" \
    "$(cat "$data_b/headroom.log.jsonl" 2>/dev/null)"

  # Fixture C: a real assistant-with-usage entry followed by a
  # "<synthetic>" one (Claude Code's model for entries like "No response
  # requested." or "API Error: Connection lost...", always with all-zero
  # usage). The synthetic entry must be skipped, not treated as "the last
  # assistant entry with usage": logging model "<synthetic>" and
  # context_tokens 0 would corrupt the growth curve Phase 4.3 depends on.
  data_c="$tmp/context-size-data-c"
  rm -rf "$data_c"
  mkdir -p "$data_c"
  fixture_c="$tmp/context-size-fixture-c.jsonl"
  cat >"$fixture_c" <<'JSONL'
{"type":"assistant","message":{"id":"msg_real","model":"claude-sonnet-5","usage":{"input_tokens":200,"output_tokens":10,"cache_read_input_tokens":300,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_synth","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL
  input=$(printf '{"transcript_path":"%s"}' "$fixture_c")
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data_c" "$hooks/context-size.sh" 2>/dev/null)
  check "never prints to the model (fixture C)" "" "$out"
  log=$(cat "$data_c/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"model":"claude-sonnet-5"'*'"context_tokens":500'*)
      echo "  ok    a <synthetic> tail entry is skipped; the real entry's model/tokens are logged" ;;
    *) echo "  FAIL  <synthetic> entry corrupted the logged model/tokens: $log"; fail=1 ;;
  esac

  # Race with Claude Code's transcript writes: Stop fires before the final
  # assistant entry is in the file. Fixture D is a turn whose previous call
  # (a tool_use, context 1000) is in the file; the final text entry
  # (context 1300) is appended about 300 ms after the hook starts. The hook
  # must wait for it, log 1300 and complete:true, not the stale 1000.
  data_d="$tmp/context-size-data-d"
  rm -rf "$data_d"
  mkdir -p "$data_d"
  fixture_d="$tmp/context-size-fixture-d.jsonl"
  cat >"$fixture_d" <<'JSONL'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"id":"msg_a","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":1,"output_tokens":5,"cache_read_input_tokens":900,"cache_creation_input_tokens":99}}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
JSONL
  final_d='{"type":"assistant","message":{"id":"msg_b","model":"claude-sonnet-5","content":[{"type":"text","text":"All done.\n"}],"usage":{"input_tokens":1,"output_tokens":7,"cache_read_input_tokens":999,"cache_creation_input_tokens":300}}}'
  input=$(printf '{"transcript_path":"%s","last_assistant_message":"All done.\\n"}' "$fixture_d")
  ( sleep 0.3; printf '%s\n' "$final_d" >>"$fixture_d" ) &
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$data_d" "$hooks/context-size.sh" 2>/dev/null)
  rc=$?
  wait
  check "late final entry: silent, exit 0" "0:" "$rc:$out"
  log=$(cat "$data_d/headroom.log.jsonl" 2>/dev/null)
  case "$log" in
    *'"context_tokens":1300'*'"complete":true'*)
      echo "  ok    waits for a final entry written after the hook started" ;;
    *) echo "  FAIL  late final entry missed: $log"; fail=1 ;;
  esac

  # Giving up: same turn, final entry never written. The stale 1000 is
  # still logged, flagged complete:false.
  rm -rf "$data_d"
  mkdir -p "$data_d"
  grep -v '"msg_b"' "$fixture_d" >"$fixture_d.tmp" && mv "$fixture_d.tmp" "$fixture_d"
  out=$(printf '%s' "$input" | HEADROOM_WAIT_TRIES=1 CLAUDE_PLUGIN_DATA="$data_d" "$hooks/context-size.sh" 2>/dev/null)
  rc=$?
  check "final entry never written: silent, exit 0" "0:" "$rc:$out"
  case "$(cat "$data_d/headroom.log.jsonl" 2>/dev/null)" in
    *'"context_tokens":1000'*'"complete":false'*)
      echo "  ok    gives up and logs the stale size flagged complete:false" ;;
    *) echo "  FAIL  timed-out wait logged wrong: $(cat "$data_d/headroom.log.jsonl" 2>/dev/null)"; fail=1 ;;
  esac

  # Ordering guard: the previous turn ended on the same text as this one
  # ("All done.\n"), and this turn's prompt and first call follow it. That
  # earlier entry is not this turn's final entry.
  rm -rf "$data_d"
  mkdir -p "$data_d"
  {
    printf '%s\n' "$final_d"
    cat "$fixture_d"
  } >"$fixture_d.tmp" && mv "$fixture_d.tmp" "$fixture_d"
  printf '%s' "$input" | HEADROOM_WAIT_TRIES=1 CLAUDE_PLUGIN_DATA="$data_d" "$hooks/context-size.sh" >/dev/null 2>&1
  case "$(cat "$data_d/headroom.log.jsonl" 2>/dev/null)" in
    *'"context_tokens":1000'*'"complete":false'*)
      echo "  ok    a previous turn's identical text is not taken as the final entry" ;;
    *) echo "  FAIL  ordering guard: $(cat "$data_d/headroom.log.jsonl" 2>/dev/null)"; fail=1 ;;
  esac

  # Missing transcript_path, unreadable file, and unparseable input all
  # degrade to silent, no log, never a block.
  check "missing transcript_path stays silent" "" \
    "$(printf '{}' | CLAUDE_PLUGIN_DATA="$data" "$hooks/context-size.sh" 2>/dev/null)"
  check "unreadable transcript stays silent" "" \
    "$(printf '{"transcript_path":"/nonexistent-transcript-xyz.jsonl"}' | CLAUDE_PLUGIN_DATA="$data" "$hooks/context-size.sh" 2>/dev/null)"
  check "unparseable input stays silent" "" \
    "$(printf 'not json' | CLAUDE_PLUGIN_DATA="$data" "$hooks/context-size.sh" 2>/dev/null)"
}

run_parser_matrix run_context_size_matrix "context-size"

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

# ======================================================================
# scripts/usage.sh
# ======================================================================

run_usage_matrix() { # label
  echo "$1"
  assert_parser "$1"
  now=$(date +%s)
  past_100=$((now - 100))
  past_50=$((now - 50))
  old_ts=$((now - 700000)) # ~8.1 days ago: outside the 7d and 5h windows.

  fixture="$tmp/usage-fixture.jsonl"
  cat >"$fixture" <<EOF
{"ts":$now,"event":"allow","hook":"check-agent","session_id":"s1","subagent_type":"headroom:scout","role":"scout","model":"default:haiku","raised":false,"isolation":"","run_in_background":false,"named":false}
{"ts":$now,"event":"allow","hook":"check-agent","session_id":"s1","subagent_type":"headroom:scout","role":"scout","model":"sonnet","raised":true,"isolation":"","run_in_background":false,"named":false}
{"ts":$now,"event":"allow","hook":"check-agent","session_id":"s2","subagent_type":"headroom:implementer","role":"implementer","model":"default:sonnet","raised":false,"isolation":"","run_in_background":true,"named":false}
{"ts":$now,"event":"deny","hook":"check-agent","detail":"headroom: model deny"}
{"ts":$now,"event":"usage","hook":"report-warning","session_id":"s1","agent_type":"headroom:scout","agent_id":"a1","model":"claude-haiku-4-5","turns":1,"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"report_bytes":900,"report_lines":70,"transcript":"ok","stop_hook_active":false}
{"ts":$now,"event":"usage","hook":"report-warning","session_id":"s1","agent_type":"headroom:scout","agent_id":"a1","model":"claude-haiku-4-5","turns":2,"input_tokens":15,"output_tokens":8,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"report_bytes":150,"report_lines":30,"transcript":"ok","stop_hook_active":false}
{"ts":$now,"event":"usage","hook":"report-warning","session_id":"s1","agent_type":"headroom:scout","agent_id":"a2","model":"claude-haiku-4-5","turns":1,"input_tokens":20,"output_tokens":10,"cache_read_input_tokens":50,"cache_creation_input_tokens":5,"report_bytes":300,"report_lines":8,"transcript":"ok","stop_hook_active":false}
{"ts":$now,"event":"usage","hook":"report-warning","session_id":"s2","agent_type":"headroom:implementer","agent_id":"a3","model":"claude-sonnet-5","turns":3,"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"report_bytes":400,"report_lines":30,"transcript":"ok","stop_hook_active":false}
{"ts":$now,"event":"usage","hook":"report-warning","session_id":"s5","agent_type":"Explore","agent_id":"a4","model":"","turns":0,"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"report_bytes":250,"report_lines":5,"transcript":"missing","stop_hook_active":false}
{"ts":$now,"event":"nudge","hook":"nudge","session_id":"s1","tool_name":"Bash","bytes":40000}
{"ts":$now,"event":"nudge","hook":"nudge","session_id":"s3","tool_name":"Read","bytes":50000}
{"ts":$now,"event":"block","hook":"block","session_id":"s1","tool_name":"Bash","bytes":8,"detail":"npm test"}
{"ts":$past_100,"event":"context","hook":"context-size","session_id":"s1","model":"claude-sonnet-5","context_tokens":2000}
{"ts":$past_50,"event":"context","hook":"context-size","session_id":"s1","model":"claude-sonnet-5","context_tokens":1000}
{"ts":$now,"event":"context","hook":"context-size","session_id":"s1","model":"claude-sonnet-5","context_tokens":1500}
{"ts":$now,"event":"context","hook":"context-size","session_id":"","model":"claude-sonnet-5","context_tokens":777}
{"ts":$old_ts,"event":"nudge","hook":"nudge","session_id":"s4","tool_name":"Bash","bytes":60000}
EOF

  # --window all: both worker groups aggregated. agent_id a1 stops twice
  # (an over-limit report blocked, then resent -- see report-warning.sh);
  # its second line's counts are already cumulative from the whole
  # transcript, so the row must reflect only that last line for a1 (input
  # 15, output 8, cache_read 100, report_bytes 150), not the sum of both a1
  # lines. Summed with a2 (input 20, output 10, cache_read 50, cache_write
  # 5, report_bytes 300): spawns 2, input 35, output 18, cache_read 150,
  # cache_write 5, report_bytes 450, tokens/report_byte (35+18+150+5)/450 =
  # 0.46. A regression that sums every usage line per agent_id instead of
  # deduping would double a1's contribution and fail this check. Context
  # latest vs max per session is distinguished, all four counters are
  # checked, and both suppressed sessions (a nudge with no allowed spawn
  # anywhere in the window) are listed.
  out=$("$scripts/usage.sh" --window all "$fixture" 2>&1)
  echo "$out" | grep -Eq 'headroom:implementer[[:space:]]+claude-sonnet-5[[:space:]]+1[[:space:]]+1000[[:space:]]+500[[:space:]]+0[[:space:]]+0[[:space:]]+400[[:space:]]+3\.75' \
    && echo "  ok    implementer worker row: spawns/tokens/report_bytes/tok-per-byte (all)" \
    || { echo "  FAIL  implementer worker row wrong (all): $out"; fail=1; }
  echo "$out" | grep -Eq 'headroom:scout[[:space:]]+claude-haiku-4-5[[:space:]]+2[[:space:]]+35[[:space:]]+18[[:space:]]+150[[:space:]]+5[[:space:]]+450[[:space:]]+0\.46' \
    && echo "  ok    scout worker row dedups a1's two stops (last line wins), sums with a2 (all)" \
    || { echo "  FAIL  scout worker row wrong (all): $out"; fail=1; }
  # agent_id a4 (Explore) logs model "" -- report-warning.sh's real shape
  # when the worker transcript is missing or unparsed. An empty model
  # column must not collapse two adjacent tabs into one under the row
  # formatter's `read`: that would shift every later column left, printing
  # the spawn count where model belongs and leaving report_bytes blank.
  echo "$out" | grep -Eq 'Explore[[:space:]]+-[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+250[[:space:]]+0\.00' \
    && echo "  ok    worker row with an empty model shows a placeholder, not a shifted row (all)" \
    || { echo "  FAIL  worker row with empty model wrong (all): $out"; fail=1; }
  echo "$out" | grep -Eq 's1[[:space:]]+claude-sonnet-5[[:space:]]+1500[[:space:]]+2000' \
    && echo "  ok    context row: latest 1500 (most recent ts), max 2000 (highest seen) (all)" \
    || { echo "  FAIL  context row wrong (all): $out"; fail=1; }
  # A context line with no session_id must not collapse two adjacent tabs
  # into one under the row formatter's `read`: that would shift model into
  # the session column and leave max blank.
  echo "$out" | grep -Eq '^  -[[:space:]]+claude-sonnet-5[[:space:]]+777[[:space:]]+777' \
    && echo "  ok    context row with an empty session_id shows a placeholder, not a shifted row (all)" \
    || { echo "  FAIL  context row with empty session_id wrong (all): $out"; fail=1; }
  echo "$out" | grep -Fq "nudges: 3   blocks: 1   denies: 1   raises: 1 (of 3 allowed spawns)" \
    && echo "  ok    counts: nudges/blocks/denies/raises (all)" \
    || { echo "  FAIL  counts line wrong (all): $out"; fail=1; }
  printf '%s\n' "$out" | grep -Eq '^  s3$' && printf '%s\n' "$out" | grep -Eq '^  s4$' \
    && echo "  ok    both nudge-but-no-spawn sessions listed (all)" \
    || { echo "  FAIL  suppressed sessions missing (all): $out"; fail=1; }

  # Default window (7d): the old nudge (~8.1 days back) drops out of both
  # the count and the suppressed-session list, but s3's still-recent nudge
  # does not. Session ids are matched anchored to their own printed line
  # (two leading spaces, nothing else), not as a bare substring: $tmp is a
  # random mktemp path and could otherwise coincidentally contain "s3"/"s4".
  out=$("$scripts/usage.sh" "$fixture" 2>&1)
  echo "$out" | grep -Fq "nudges: 2   blocks: 1   denies: 1   raises: 1 (of 3 allowed spawns)" \
    && echo "  ok    counts exclude the out-of-window nudge (default 7d)" \
    || { echo "  FAIL  counts line wrong (7d): $out"; fail=1; }
  if printf '%s\n' "$out" | grep -Eq '^  s4$'; then
    echo "  FAIL  s4 should drop out of the 7d window: $out"; fail=1
  elif printf '%s\n' "$out" | grep -Eq '^  s3$'; then
    echo "  ok    s3 still listed, s4 dropped (default 7d)"
  else
    echo "  FAIL  s3 missing from suppressed sessions (7d): $out"; fail=1
  fi

  # --window 5h: same exclusion, narrower window; also checks the window
  # label in the header.
  out=$("$scripts/usage.sh" --window 5h "$fixture" 2>&1)
  case "$out" in
    *"window: 5h"*) echo "  ok    window label reflects --window 5h" ;;
    *) echo "  FAIL  window label missing for 5h: $out"; fail=1 ;;
  esac
  echo "$out" | grep -Fq "nudges: 2   blocks: 1   denies: 1   raises: 1 (of 3 allowed spawns)" \
    && echo "  ok    counts exclude the out-of-window nudge (5h)" \
    || { echo "  FAIL  counts line wrong (5h): $out"; fail=1; }

  # Unknown --window value is rejected, not silently ignored.
  out=$("$scripts/usage.sh" --window 3d "$fixture" 2>/dev/null)
  rc=$?
  check "unknown --window value exits non-zero" "2" "$rc"
  check "unknown --window value prints nothing to stdout" "" "$out"

  # Path resolution: no argument falls back to
  # $CLAUDE_PLUGIN_DATA/headroom.log.jsonl.
  data="$tmp/usage-plugin-data"
  rm -rf "$data"
  mkdir -p "$data"
  cp "$fixture" "$data/headroom.log.jsonl"
  out=$(CLAUDE_PLUGIN_DATA="$data" "$scripts/usage.sh" --window all 2>&1)
  case "$out" in
    *"$data/headroom.log.jsonl"*) echo "  ok    falls back to \$CLAUDE_PLUGIN_DATA/headroom.log.jsonl" ;;
    *) echo "  FAIL  did not fall back to \$CLAUDE_PLUGIN_DATA: $out"; fail=1 ;;
  esac

  # Path resolution: with neither an argument nor $CLAUDE_PLUGIN_DATA
  # pointing at a real file, and no ~/.claude/plugins/data/headroom*/ under
  # a throwaway HOME, this fails loudly instead of silently printing an
  # empty report.
  fake_home="$tmp/usage-fake-home"
  rm -rf "$fake_home"
  mkdir -p "$fake_home"
  stderr_file="$tmp/usage-stderr.txt"
  out=$(HOME="$fake_home" CLAUDE_PLUGIN_DATA=/nonexistent "$scripts/usage.sh" 2>"$stderr_file")
  rc=$?
  check "no log file found: exits non-zero" "1" "$rc"
  check "no log file found: prints nothing to stdout" "" "$out"
  errline=$(cat "$stderr_file" 2>/dev/null)
  rm -f "$stderr_file"
  case "$errline" in
    *"no readable headroom.log.jsonl"*) echo "  ok    missing log file notes the gap on stderr" ;;
    *) echo "  FAIL  missing log file did not explain itself: $errline"; fail=1 ;;
  esac

  # Path resolution: the newest ~/.claude/plugins/data/headroom*/ directory
  # wins, by mtime, over an older one.
  rm -rf "$fake_home"
  mkdir -p "$fake_home/.claude/plugins/data/headroom-old" "$fake_home/.claude/plugins/data/headroom-inline"
  printf '{"ts":1,"event":"nudge","hook":"nudge","session_id":"old","tool_name":"Bash","bytes":1}\n' >"$fake_home/.claude/plugins/data/headroom-old/headroom.log.jsonl"
  sleep 1
  printf '{"ts":1,"event":"nudge","hook":"nudge","session_id":"newest","tool_name":"Bash","bytes":1}\n' >"$fake_home/.claude/plugins/data/headroom-inline/headroom.log.jsonl"
  out=$(HOME="$fake_home" CLAUDE_PLUGIN_DATA=/nonexistent "$scripts/usage.sh" --window all 2>&1)
  case "$out" in
    *"headroom-inline/headroom.log.jsonl"*) echo "  ok    picks the newest headroom*/ directory by mtime" ;;
    *) echo "  FAIL  did not pick the newest headroom*/ directory: $out"; fail=1 ;;
  esac
}

run_parser_matrix run_usage_matrix "usage.sh"

[ $fail -eq 0 ] && echo "all hook tests passed" || { echo "hook tests FAILED"; exit 1; }

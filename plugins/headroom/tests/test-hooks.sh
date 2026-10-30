#!/bin/sh
# Replays the Agent guard against every input case on both parser paths
# (jq, python3) and checks the SessionStart injector. Run from anywhere:
#   sh plugins/headroom/tests/test-hooks.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
# HEADROOM_TEST_SH=dash runs every hook through that shell.
runner=${HEADROOM_TEST_SH:-}
guard="$runner $root/hooks/check-agent.sh"
inject="$runner $root/hooks/inject-rules.sh"
wfguard="$runner $root/hooks/check-workflow.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: expected '$2', got '$3'"; fail=1; fi
}

# decision <json> -> allow | deny | skip (stderr note, no stdout)
decision() {
  out=$(printf '%s' "$1" | $guard 2>/dev/null)
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
  check "model fable with effort"   deny  "$(decision '{"tool_input":{"model":"fable","effort":"low"}}')"
  check "fork with effort"          deny  "$(decision '{"tool_input":{"subagent_type":"fork","model":"sonnet","effort":"low"}}')"
  check "effort only, no model"     deny  "$(decision '{"tool_input":{"effort":"low"}}')"
  check "model haiku"               allow "$(decision '{"tool_input":{"model":"haiku","effort":"low"}}')"
  check "model sonnet"              allow "$(decision '{"tool_input":{"model":"sonnet","effort":"medium","subagent_type":"browser-scout"}}')"
  check "model opus"                allow "$(decision '{"tool_input":{"model":"opus","effort":"high"}}')"
  check "opus xhigh"                allow "$(decision '{"tool_input":{"model":"opus","effort":"xhigh"}}')"
  check "opus max"                  allow "$(decision '{"tool_input":{"model":"opus","effort":"max"}}')"
  check "sonnet, no effort"         deny  "$(decision '{"tool_input":{"model":"sonnet"}}')"
  check "sonnet, null effort"       deny  "$(decision '{"tool_input":{"model":"sonnet","effort":null}}')"
  check "sonnet, effort extreme"    deny  "$(decision '{"tool_input":{"model":"sonnet","effort":"extreme"}}')"
  check "sonnet, effort High"       deny  "$(decision '{"tool_input":{"model":"sonnet","effort":"High"}}')"
  check "sonnet, empty effort"      deny  "$(decision '{"tool_input":{"model":"sonnet","effort":""}}')"
  check "scout, no model"           deny  "$(decision '{"tool_input":{"subagent_type":"scout"}}')"
  check "headroom:scout, no model"  deny  "$(decision '{"tool_input":{"subagent_type":"headroom:scout"}}')"
  check "headroom:scout, null model" deny "$(decision '{"tool_input":{"subagent_type":"headroom:scout","model":null}}')"
  check "headroom:scout, haiku, no effort" deny "$(decision '{"tool_input":{"subagent_type":"headroom:scout","model":"haiku"}}')"
  check "headroom:scout, haiku, medium" allow "$(decision '{"tool_input":{"subagent_type":"headroom:scout","model":"haiku","effort":"medium"}}')"
  check "headroom:scout, model fable" deny "$(decision '{"tool_input":{"subagent_type":"headroom:scout","model":"fable"}}')"
  check "general-purpose, no model" deny  "$(decision '{"tool_input":{"subagent_type":"general-purpose"}}')"
  check "effort is a number"        deny  "$(decision '{"tool_input":{"model":"sonnet","effort":5}}')"
  check "fork, effort is a number"  deny  "$(decision '{"tool_input":{"subagent_type":"fork","effort":5}}')"
  check "effort is an array"        deny  "$(decision '{"tool_input":{"effort":["x"]}}')"
  check "effort is an object"       deny  "$(decision '{"tool_input":{"model":"sonnet","effort":{"a":1}}}')"
  check "effort with newline"       deny  "$(decision '{"tool_input":{"model":"sonnet","effort":"high\nx"}}')"
  check "model with newline"        deny  "$(decision '{"tool_input":{"model":"sonnet\nhigh"}}')"
  check "unparseable input"         allow "$(decision 'not json')"
  check "empty input"               allow "$(decision '')"
}

if command -v jq >/dev/null 2>&1; then
  run_matrix "guard via jq"
  echo "  deny output is valid JSON with a reason:"
  reason=$(printf '{"tool_input":{}}' | $guard | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
  case "$reason" in "headroom:"*) echo "  ok    reason text" ;; *) echo "  FAIL  reason text: '$reason'"; fail=1 ;; esac
else
  echo "jq not installed; skipping jq path"
fi

if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 run_matrix "guard via python3"
  echo "  python3 path really parses:"
  out=$(printf '{"tool_input":{"model":"opus","effort":"high"}}' | HEADROOM_PARSER=python3 $guard 2>&1)
  check "no parse-failure note on stderr" "" "$out"
else
  echo "python3 not installed; skipping python3 path"
fi

wf_decision() { # <json> -> allow | deny | other
  out=$(printf '%s' "$1" | $wfguard 2>/dev/null)
  case "$out" in
    "") printf 'allow' ;;
    *'"permissionDecision":"deny"'*) printf 'deny' ;;
    *) printf 'other' ;;
  esac
}

wfscript() { # label expected script
  printf '%s' "$3" > "$tmp/s.js"
  check "$1" "$2" "$(wf_decision "{\"tool_input\":{\"scriptPath\":\"$tmp/s.js\"}}")"
}

workflow_matrix() { # label
  echo "$1"
  printf "agent('x', { model: 'fable' })\n" > "$tmp/fable.js"
  check "inline model fable"        deny  "$(wf_decision '{"tool_input":{"script":"agent(\"x\", { model: \u0027fable\u0027 })"}}')"
  check "inline model mythos"       deny  "$(wf_decision '{"tool_input":{"script":"agent(\"x\", { model: \"mythos\" })"}}')"
  check "model split across lines"  deny  "$(wf_decision '{"tool_input":{"script":"agent(\"x\", { model:\n  \u0027fable\u0027 })"}}')"
  check "scriptPath with fable"     deny  "$(wf_decision "{\"tool_input\":{\"scriptPath\":\"$tmp/fable.js\"}}")"
  check "named workflow"            allow "$(wf_decision '{"tool_input":{"name":"review-changes"}}')"
  check "all agents sonnet"         allow "$(wf_decision '{"tool_input":{"script":"agent(\"a\", { model: \u0027sonnet\u0027, effort: \u0027medium\u0027 }); agent(\"b\", { model: \u0027sonnet\u0027, effort: \u0027medium\u0027 })"}}')"
  check "unparseable input"         allow "$(wf_decision 'not json')"
  wfscript "agent without options"   deny  "agent('do x')"
  wfscript "agent without model"     deny  "agent(p, {label: 'a'})"
  wfscript "one of two lacks model"  deny  "agent(p, {model: 'haiku'}); agent(q, {label: 'b'})"
  wfscript "multi-line with model"   allow "agent(p, {
 label: 'a',
 model: 'haiku',
 effort: 'medium'
})"
  wfscript "no agent call"           allow "const x = 1; log(x)"
  wfscript "reagent without model"   allow "reagent(p, {label: 'a'})"
  wfscript "agent after punctuation" deny  "await Promise.all([agent(p), agent(q, {model: 'sonnet'})])"
  wfscript "template text with agent word" allow 'const t = `QEMU guest agent (qemu-ga)`; agent(p, {model: '"'haiku'"', effort: '"'medium'"'})'
  wfscript "string literal mentions call"  allow 'const t = "agent(prompt,{model,schema})"; agent(p, {model: '"'sonnet'"', effort: '"'medium'"'})'
  wfscript "shorthand model, more keys"    allow 'agent(p, { label, phase, model, effort, schema })'
  wfscript "shorthand model, alone"        allow 'agent(p, {model, effort: '"'medium'"'})'
  wfscript "model only in line comment"    deny  "agent(p, {label:'x'}) // model: haiku"
  wfscript "model only in block comment"   deny  "agent(p, {label:'x'}) /* model: haiku */"
  wfscript "model only in string argument" deny  "agent('choose a model: any', {label:'x'})"
  wfscript "template with expression"      allow 'agent(p, {model: `${m}`, effort: '"'medium'"'})'
  wfscript "model key in template expr"    allow 'agent(`x ${y}`, {model: '"'haiku'"', effort: '"'medium'"'})'
  wfscript "model, no effort"              deny  "agent(p, {model: 'haiku'})"
  wfscript "second call lacks effort"      deny  "agent(p, {model: 'haiku', effort: 'low'}); agent(q, {model: 'sonnet'})"
  wfscript "effort only in line comment"   deny  "agent(p, {model: 'haiku'}) // effort: 'low'"
  wfscript "effort only in block comment"  deny  "agent(p, {model: 'haiku'}) /* effort: 'low' */"
  wfscript "effort only in string argument" deny "agent('use effort: high', {model: 'haiku'})"
  wfscript "shorthand model and effort"    allow "agent(p, {model, effort})"
  wfscript "shorthand among other keys"    allow "agent(p, { label, model, effort, schema })"
  wfscript "model and effort on own lines" allow "agent(p, {
 model: 'haiku',
 effort: 'low'
})"
  wfscript "keys literal, values variables" allow "agent(p, {model: m, effort: e})"
  printf "agent(p, {model: 'haiku'})" > "$tmp/noeffort.js"
  out=$(printf '{"tool_input":{"scriptPath":"%s"}}' "$tmp/noeffort.js" | $wfguard 2>/dev/null)
  check "no-effort reason names the rule" 1 "$(printf '%s' "$out" | grep -c 'names no effort')"
  check "no-effort reason lists all levels" 1 "$(printf '%s' "$out" | grep -c 'low, medium, high, xhigh or max')"
  printf "agent(p, {label: 'a'})" > "$tmp/nomodel.js"
  reason=$(printf '{"tool_input":{"scriptPath":"%s"}}' "$tmp/nomodel.js" | $wfguard 2>/dev/null | grep -c 'write the model literally')
  check "deny reason names the rule" 1 "$reason"
}

if command -v jq >/dev/null 2>&1; then
  workflow_matrix "workflow guard via jq"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 workflow_matrix "workflow guard via python3"
fi

budget="$runner $root/hooks/budget.sh"

blob() { head -c "$1" /dev/zero | tr '\0' 'a'; }

# bjson <tool> <bytes> [extra top-level json fields] -> hook input
bjson() {
  case "$1" in
    Read) printf '{"session_id":"s1","prompt_id":"p1"%s,"tool_name":"Read","tool_response":{"file":{"content":"%s"}}}' "${3:-}" "$(blob "$2")" ;;
    Bash) printf '{"session_id":"s1","prompt_id":"p1"%s,"tool_name":"Bash","tool_response":{"stdout":"%s","stderr":""}}' "${3:-}" "$(blob "$2")" ;;
  esac
}

# bout <json> -> nudge | quiet (data dir from $BD)
bout() {
  out=$(printf '%s' "$1" | CLAUDE_PLUGIN_DATA="$BD" $budget 2>/dev/null)
  printf '%s' "$out" >"$tmp/eraw"
  case "$out" in
    "") printf 'quiet' ;;
    *'"hookEventName":"PostToolUse"'*'headroom:scout'*) printf 'nudge' ;;
    *) printf 'other' ;;
  esac
}

# ejson <tool> <path> [extra top-level json fields] -> hook input for an edit
ejson() {
  case "$1" in
    NotebookEdit) printf '{"session_id":"s1","prompt_id":"p1"%s,"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"},"tool_response":{"ok":true}}' "${3:-}" "$2" ;;
    *) printf '{"session_id":"s1","prompt_id":"p1"%s,"tool_name":"%s","tool_input":{"file_path":"%s"},"tool_response":{"ok":true}}' "${3:-}" "$1" "$2" ;;
  esac
}

# eout <json> -> edit | quiet | other (data dir from $BD)
eout() {
  out=$(printf '%s' "$1" | CLAUDE_PLUGIN_DATA="$BD" $budget 2>/dev/null)
  printf '%s' "$out" >"$tmp/eraw"
  case "$out" in
    "") printf 'quiet' ;;
    *'"hookEventName":"PostToolUse"'*'general-purpose'*'sonnet'*) printf 'edit' ;;
    *) printf 'other' ;;
  esac
}

budget_matrix() { # label
  echo "$1"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "read 1 of 3"        quiet "$(bout "$(bjson Read 10000)")"
  check "read 2 of 3"        quiet "$(bout "$(bjson Read 10000)")"
  check "read 3 of 3 nudges" nudge "$(bout "$(bjson Read 10000)")"
  check "read 4 stays quiet" quiet "$(bout "$(bjson Read 10000)")"
  check "one state file"     1 "$(ls "$BD" | grep -c '^budget-s1$')"
  check "no leftover lock"   0 "$(ls "$BD" | grep -c 'lock')"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  for i in 1 2 3 4; do r=$(bout "$(bjson Read 10000 ',"agent_id":"w1"')"); done
  check "agent_id: never"    quiet "$r"
  check "agent_id: no state" 0 "$(ls "$BD" | wc -l | tr -d ' ')"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "persisted bash"     quiet "$(bout '{"session_id":"s1","prompt_id":"p1","tool_name":"Bash","tool_response":{"stdout":"'"$(blob 50000)"'","stderr":"","persistedOutputPath":"/tmp/x"}}')"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "stdout+stderr nudges" nudge "$(bout '{"session_id":"s1","prompt_id":"p1","tool_name":"Bash","tool_response":{"stdout":"'"$(blob 20000)"'","stderr":"'"$(blob 10000)"'"}}')"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "stdout alone quiet" quiet "$(bout "$(bjson Bash 20000)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "new prompt resets (1)" quiet "$(bout "$(bjson Read 20000)")"
  check "new prompt resets (2)" quiet "$(bout "$(bjson Read 20000 | sed 's/"p1"/"p2"/')")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "budget 1000"        nudge "$(HEADROOM_READ_BUDGET=1000 bout "$(bjson Read 1500)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  nt=$(HEADROOM_READ_BUDGET=1000 bout "$(bjson Read 1500)" >/dev/null; cat "$tmp/eraw")
  case $nt in *'long runs (tests, builds, logs) and many-file sweeps'*) r=yes ;; *) r=no ;; esac
  check "nudge names long runs" yes "$r"
  case $nt in *'Remaining lookups'*) r=yes ;; *) r=no ;; esac
  check "nudge drops old wording" no "$r"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "budget 0 never"     quiet "$(HEADROOM_READ_BUDGET=0 bout "$(bjson Read 90000)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "edit a"             quiet "$(eout "$(ejson Edit /w/a)")"
  check "write b"            quiet "$(eout "$(ejson Write /w/b)")"
  check "edit a again"       quiet "$(eout "$(ejson Edit /w/a)")"
  check "edit b (2 distinct)" quiet "$(eout "$(ejson Edit /w/b)")"
  check "edit c nudges"      edit "$(eout "$(ejson Edit /w/c)")"
  case "$(cat "$tmp/eraw")" in *"model sonnet, effort medium"*) echo "  ok    doing hint names model sonnet, effort medium" ;; *) echo "  FAIL  doing hint lacks model sonnet, effort medium"; fail=1 ;; esac
  check "write d stays quiet" quiet "$(eout "$(ejson Write /w/d)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  eout "$(ejson Edit /w/a)" >/dev/null; eout "$(ejson Edit /w/b)" >/dev/null
  check "notebook_path counts" edit "$(eout "$(ejson NotebookEdit /w/n.ipynb)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  eout "$(ejson Edit /w/a)" >/dev/null; eout "$(ejson Edit /w/b)" >/dev/null
  eout "$(ejson Edit /w/c)" >/dev/null
  check "new prompt resets edits" quiet "$(eout "$(ejson Edit /w/d | sed 's/"p1"/"p2"/')")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  for p in a b c d e; do r=$(eout "$(ejson Edit /w/$p ',"agent_id":"w1"')"); done
  check "edit agent_id: never" quiet "$r"
  check "edit agent_id: no state" 0 "$(ls "$BD" | wc -l | tr -d ' ')"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  r=quiet; for p in a b c d e; do o=$(HEADROOM_EDIT_BUDGET=0 eout "$(ejson Edit /w/$p)"); [ "$o" = quiet ] || r=$o; done
  check "edit budget 0 never" quiet "$r"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "edit budget 1 first edit" edit "$(HEADROOM_EDIT_BUDGET=1 eout "$(ejson Edit /w/a)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "edits do not feed read budget" quiet "$(bout "$(ejson Edit /w/a)")"
  # Prompt restart: both budgets reset on a changed prompt_id.
  p2() { printf '%s' "$1" | sed 's/"p1"/"p2"/'; }
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  bout "$(bjson Read 30000)" >/dev/null
  eout "$(ejson Edit /w/a)" >/dev/null; eout "$(ejson Edit /w/b)" >/dev/null
  check "p1 edit nudge fires"       edit  "$(eout "$(ejson Edit /w/c)")"
  check "p2 read restarts (1)"      quiet "$(bout "$(p2 "$(bjson Read 20000)")")"
  check "p2 read nudges again"      nudge "$(bout "$(p2 "$(bjson Read 10000)")")"
  check "p2 edit a"                 quiet "$(eout "$(p2 "$(ejson Edit /w/a)")")"
  check "p2 edit b"                 quiet "$(eout "$(p2 "$(ejson Edit /w/b)")")"
  check "p2 edit c nudges again"    edit  "$(eout "$(p2 "$(ejson Edit /w/c)")")"
  check "back to p1 restarts reads" quiet "$(bout "$(bjson Read 20000)")"
  check "back to p1 reads nudge"    nudge "$(bout "$(bjson Read 10000)")"
  check "back to p1 restarts edits" quiet "$(eout "$(ejson Edit /w/a)")"
  check "back to p1 edit b"         quiet "$(eout "$(ejson Edit /w/b)")"
  check "back to p1 edit c nudges"  edit  "$(eout "$(ejson Edit /w/c)")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  bout "$(bjson Read 20000 | sed 's/"s1"/"s2"/')" >/dev/null
  before=$(cat "$BD/budget-s2")
  bout "$(bjson Read 30000)" >/dev/null
  bout "$(p2 "$(bjson Read 30000)")" >/dev/null
  check "other session state untouched" "$before" "$(cat "$BD/budget-s2")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  np() { printf '%s' "$1" | sed 's/"prompt_id":"p1",//'; }
  check "no prompt_id: read 1"      quiet "$(bout "$(np "$(bjson Read 20000)")")"
  check "no prompt_id: read nudges" nudge "$(bout "$(np "$(bjson Read 10000)")")"
  check "no prompt_id: read once"   quiet "$(bout "$(np "$(bjson Read 30000)")")"
  eout "$(np "$(ejson Edit /w/a)")" >/dev/null; eout "$(np "$(ejson Edit /w/b)")" >/dev/null
  check "no prompt_id: edit nudges" edit  "$(eout "$(np "$(ejson Edit /w/c)")")"
  check "no prompt_id: edit once"   quiet "$(eout "$(np "$(ejson Edit /w/d)")")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "unparseable input"  quiet "$(bout 'not json')"
}

if command -v jq >/dev/null 2>&1; then
  budget_matrix "budget via jq"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 budget_matrix "budget via python3"
fi
echo "budget without a parser"
err=$(printf '%s' "$(bjson Read 30000)" | HEADROOM_PARSER=none CLAUDE_PLUGIN_DATA="$tmp" $budget 2>&1 >/dev/null); rc=$?
check "parser none exits 0" 0 "$rc"
check "parser none: one stderr line" 1 "$(printf '%s\n' "$err" | grep -c .)"

# secs <cmd...> -> elapsed whole milliseconds (python3 timer)
millis() {
  python3 -c 'import subprocess,sys,time
t=time.time(); subprocess.run(sys.argv[1:],stdin=open(sys.stdin.fileno(),closefd=False),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(int((time.time()-t)*1000))' "$@"
}

hardening_matrix() { # label
  echo "$1"
  # Stale lock (older than 10 s) is removed and counting resumes.
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  mkdir "$BD/budget-s1.lock"; touch -t 202001010000 "$BD/budget-s1.lock"
  check "stale lock: nudge fires" nudge "$(HEADROOM_READ_BUDGET=1000 bout "$(bjson Read 1500)")"
  check "stale lock: removed" 0 "$(ls "$BD" | grep -c lock)"
  # Fresh lock held past the retry window: exit 0, one stderr line.
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  mkdir "$BD/budget-s1.lock"
  err=$(bjson Read 30000 | CLAUDE_PLUGIN_DATA="$BD" $budget 2>&1 >/dev/null); rc=$?
  check "busy lock: exit 0" 0 "$rc"
  check "busy lock: one headroom line" 1 "$(printf '%s\n' "$err" | grep -c '^headroom:')"
  check "busy lock: no extra lines" 1 "$(printf '%s\n' "$err" | grep -c .)"
  # Unwritable data folder: exit 0, one stderr line, fast.
  if [ "$(id -u)" -ne 0 ]; then
    BD=$(mktemp -d "$tmp/bd.XXXXXX"); chmod 500 "$BD"
    err=$(bjson Read 30000 | CLAUDE_PLUGIN_DATA="$BD" $budget 2>&1 >/dev/null); rc=$?
    check "unwritable dir: exit 0" 0 "$rc"
    check "unwritable dir: one headroom line" 1 "$(printf '%s\n' "$err" | grep -c '^headroom:')"
    bjson Read 30000 > "$tmp/in.json"
    ms=$(CLAUDE_PLUGIN_DATA="$BD" millis $budget < "$tmp/in.json")
    [ "$ms" -lt 500 ] && r=fast || r="slow ${ms}ms"
    check "unwritable dir: under 0.5 s" fast "$r"
    chmod 700 "$BD"
  fi
  # prompt_id with a newline is sanitised and still counts.
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "newline in prompt_id counts" nudge "$(bout "$(bjson Read 30000 | sed 's/"p1"/"p\\n1"/')")"
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  check "newline in session_id counts" nudge "$(bout "$(bjson Read 30000 | sed 's/"s1"/"s\\n1"/')")"
  # 2 MB of Bash stdout counts its bytes and finishes fast.
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  bjson Bash 2000000 > "$tmp/big.json"
  out=$(CLAUDE_PLUGIN_DATA="$BD" $budget < "$tmp/big.json" 2>/dev/null)
  case "$out" in *'headroom:scout'*) r=nudge ;; *) r=quiet ;; esac
  check "2 MB stdout nudges" nudge "$r"
  check "2 MB stdout counted" 2000000 "$(sed -n 's/^read_bytes=//p' "$BD/budget-s1")"
  ms=$(CLAUDE_PLUGIN_DATA="$BD" millis $budget < "$tmp/big.json")
  [ "$ms" -lt 1000 ] && r=fast || r="slow ${ms}ms"
  check "2 MB stdout under 1 s" fast "$r"
  # Multi-byte output counts bytes, not characters.
  BD=$(mktemp -d "$tmp/bd.XXXXXX")
  bout '{"session_id":"s1","prompt_id":"p1","tool_name":"Bash","tool_response":{"stdout":"äöü","stderr":""}}' >/dev/null
  check "utf-8 counts bytes" 6 "$(sed -n 's/^read_bytes=//p' "$BD/budget-s1")"
  # Checks honour HEADROOM_PARSER=none and report parse failures once.
  for g in "$guard" "$wfguard"; do
    err=$(printf '{"tool_input":{}}' | HEADROOM_PARSER=none $g 2>&1 >/dev/null); rc=$?
    out=$(printf '{"tool_input":{}}' | HEADROOM_PARSER=none $g 2>/dev/null)
    check "parser none: exit 0 ($(basename "${g##* }"))" 0 "$rc"
    check "parser none: no stdout ($(basename "${g##* }"))" "" "$out"
    check "parser none: one stderr line ($(basename "${g##* }"))" 1 "$(printf '%s\n' "$err" | grep -c '^headroom:')"
    err=$(printf 'not json' | $g 2>&1 >/dev/null)
    out=$(printf 'not json' | $g 2>/dev/null)
    check "not json: allow ($(basename "${g##* }"))" "" "$out"
    check "not json: one stderr line ($(basename "${g##* }"))" 1 "$(printf '%s\n' "$err" | grep -c '^headroom:')"
  done
  err=$(printf '{"tool_input":{"scriptPath":"%s/missing.js"}}' "$tmp" | $wfguard 2>&1 >/dev/null)
  out=$(printf '{"tool_input":{"scriptPath":"%s/missing.js"}}' "$tmp" | $wfguard 2>/dev/null)
  check "missing scriptPath: allow" "" "$out"
  check "missing scriptPath: one stderr line" 1 "$(printf '%s\n' "$err" | grep -c '^headroom:')"
}

if command -v jq >/dev/null 2>&1; then
  hardening_matrix "hardening via jq"
fi
if command -v python3 >/dev/null 2>&1; then
  HEADROOM_PARSER=python3 hardening_matrix "hardening via python3"
fi

echo "hooks.json matcher"
want='^(Read|Bash|Grep|Glob|WebFetch|WebSearch|Edit|Write|NotebookEdit)$|^mcp__'
got=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["PostToolUse"][0]["matcher"])' "$root/hooks/hooks.json" 2>/dev/null)
check "PostToolUse matcher is anchored" "$want" "$got"

echo "injector"
out=$(CLAUDE_PLUGIN_ROOT="$root" $inject </dev/null)
case "$out" in "<headroom>"*"</headroom>") echo "  ok    wrapped in <headroom> tags" ;; *) echo "  FAIL  tag wrapping"; fail=1 ;; esac
case "$out" in *"# Headroom"*) echo "  ok    contains rules.md" ;; *) echo "  FAIL  rules.md missing"; fail=1 ;; esac
case "$out" in *"## Workflows"*) echo "  ok    rules has ## Workflows" ;; *) echo "  FAIL  ## Workflows missing"; fail=1 ;; esac
case "$out" in *"headroom:scout"*) echo "  ok    rules names headroom:scout" ;; *) echo "  FAIL  headroom:scout missing"; fail=1 ;; esac
case "$out" in *"Agent check"*"Workflow check"*) echo "  ok    preface names Agent and Workflow checks" ;; *) echo "  FAIL  preface lacks Agent and Workflow"; fail=1 ;; esac
pre=${out%%"# Headroom"*}
case "$pre" in *"Agent check"*effort*"Workflow check"*effort*) echo "  ok    preface names effort under both checks" ;; *) echo "  FAIL  preface lacks effort under both checks"; fail=1 ;; esac
case "$pre" in *scout*) echo "  FAIL  preface contains scout"; fail=1 ;; *) echo "  ok    preface does not contain scout" ;; esac
check "empty plugin root prints nothing" "" "$(CLAUDE_PLUGIN_ROOT=/nonexistent $inject </dev/null)"

echo "texts"
for g in "$guard" "$wfguard"; do
  if [ "$g" = "$guard" ]; then in='{"tool_input":{}}'; else in='{"tool_input":{"script":"agent(p, {})"}}'; fi
  r=$(printf '%s' "$in" | $g 2>/dev/null)
  case "$r" in *CLAUDE_CODE_SUBAGENT_MODEL*) echo "  ok    no-model reason names CLAUDE_CODE_SUBAGENT_MODEL ($(basename "${g##* }"))" ;; *) echo "  FAIL  no-model reason lacks CLAUDE_CODE_SUBAGENT_MODEL ($(basename "${g##* }"))"; fail=1 ;; esac
done
for in in '{"tool_input":{"subagent_type":"fork","model":"sonnet"}}' '{"tool_input":{"model":"fable"}}'; do
  r=$(printf '%s' "$in" | $guard 2>/dev/null)
  case "$r" in *haiku*sonnet*opus*) echo "  ok    deny reason names haiku, sonnet, opus" ;; *) echo "  FAIL  deny reason lacks the three models: $in"; fail=1 ;; esac
done
for in in '{"tool_input":{"subagent_type":"fork","model":"sonnet"}}' '{"tool_input":{}}' '{"tool_input":{"model":"fable"}}' '{"tool_input":{"model":"sonnet"}}' '{"tool_input":{"model":"sonnet","effort":"extreme"}}'; do
  r=$(printf '%s' "$in" | $guard 2>/dev/null)
  ok=1
  for w in haiku sonnet opus low medium high xhigh max; do case "$r" in *"$w"*) ;; *) ok=0 ;; esac; done
  if [ $ok = 1 ]; then echo "  ok    deny reason names models and all five levels"; else echo "  FAIL  deny reason lacks a model or level: $in"; fail=1; fi
done
r=$(printf '{"tool_input":{"model":"sonnet"}}' | $guard 2>/dev/null)
case "$r" in *'"headroom:'*effort*) echo "  ok    missing-effort reason starts with headroom: and names effort" ;; *) echo "  FAIL  missing-effort reason text"; fail=1 ;; esac
case "$out" in *"Agent check refuses"*mythos*"Workflow check"*) echo "  FAIL  preface claims the Agent check refuses mythos"; fail=1 ;; *) echo "  ok    preface makes no mythos claim for the Agent check" ;; esac
case "$out" in *"Workflow check"*mythos*) echo "  ok    preface lists mythos under the Workflow check" ;; *) echo "  FAIL  preface lacks mythos under the Workflow check"; fail=1 ;; esac
d=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["description"])' "$root/hooks/hooks.json" 2>/dev/null)
case "$d" in *Workflow*) echo "  ok    description field names Workflow" ;; *) echo "  FAIL  description field lacks Workflow"; fail=1 ;; esac
case "$d" in *effort*) echo "  ok    description field names effort" ;; *) echo "  FAIL  description field lacks effort"; fail=1 ;; esac
limits=$(sed -n '/^## Limits/,/^## Test/p' "$root/README.md")
check "README Limits names the Agent check" 1 "$(printf '%s\n' "$limits" | grep -c 'Agent check' | sed 's/^[1-9][0-9]*$/1/')"
check "README Limits names the Workflow check" 1 "$(printf '%s\n' "$limits" | grep -c 'Workflow check' | sed 's/^[1-9][0-9]*$/1/')"
check "README Limits says the Workflow check leaves the effort value unchecked" 1 "$(printf '%s\n' "$limits" | grep -c 'leaves its value unchecked' | sed 's/^[1-9][0-9]*$/1/')"
check "hooks.json description drops 'allowed model and effort'" 0 "$(grep -c 'allowed model and effort' "$root/hooks/hooks.json")"
check "no contrastive phrasing" 0 "$(cat "$root/rules.md" "$root/agents/scout.md" "$root/hooks/inject-rules.sh" "$root/hooks/hooks.json" | grep -cE 'instead of|rather than|, not |not just')"
rules_check() { # file: required headings, tiers and 37k present; old headings absent; under 4,800 bytes
  for s in '## Spawn at all?' '## Tiers' '## Reviews' '## Workflows' '37k' \
    '**haiku, medium**' '**sonnet, medium**' '**sonnet, high**' '**opus, medium**' '**opus, high**'; do
    grep -qF -- "$s" "$1" || return 1
  done
  for s in '## Reading' '## Parallelism' '## Every brief' '## Pre-authorisation' '## Large changes'; do
    ! grep -qF -- "$s" "$1" || return 1
  done
  [ "$(wc -c < "$1")" -lt 4800 ]
}
if rules_check "$root/rules.md"; then echo "  ok    rules sections and tiers present"; else echo "  FAIL  rules sections or tiers missing"; fail=1; fi
# b4aaec7 is the 0.4 merge commit; fee486f is the 0.5 merge commit.
if git -C "$root/../.." show b4aaec7:plugins/headroom/rules.md > "$tmp/rules-0.4.md" 2>/dev/null; then
  if rules_check "$tmp/rules-0.4.md"; then echo "  FAIL  rules check accepts the 0.4 rules"; fail=1; else echo "  ok    rules check rejects the 0.4 rules"; fi
else
  echo "  FAIL  git show b4aaec7:plugins/headroom/rules.md failed"; fail=1
fi
if git -C "$root/../.." show fee486f:plugins/headroom/rules.md > "$tmp/rules-0.5.md" 2>/dev/null; then
  if rules_check "$tmp/rules-0.5.md"; then echo "  FAIL  rules check accepts the 0.5 rules"; fail=1; else echo "  ok    rules check rejects the 0.5 rules"; fi
else
  echo "  FAIL  git show fee486f:plugins/headroom/rules.md failed"; fail=1
fi
check "scout.md has no 'instead of'" 0 "$(grep -cE 'instead of|, not |not just' "$root/agents/scout.md")"
check "scout.md sets effort medium" 1 "$(grep -c '^effort: medium$' "$root/agents/scout.md")"
check "README drops CLAUDE_CODE_SUBAGENT_MODEL=sonnet" 0 "$(grep -c 'CLAUDE_CODE_SUBAGENT_MODEL=sonnet' "$root/README.md")"
check "README names 2.1.312" 1 "$(grep -c '2\.1\.312' "$root/README.md" | sed 's/^[1-9][0-9]*$/1/')"
check "README names the fallback folder" 1 "$(grep -c 'TMPDIR:-/tmp}/headroom' "$root/README.md" | sed 's/^[1-9][0-9]*$/1/')"
check "README drops the scout model exception" 0 "$(grep -c 'passes without a' "$root/README.md")"
check "README drops workflow pre-authorisation" 0 "$(grep -c 'pre-authorise Haiku, Sonnet and Opus spawns, workflows' "$root/README.md")"
check "README warns about saved scripts" 1 "$(grep -ciE 'saved workflow scripts?.*effort|effort.*saved workflow scripts?' "$root/README.md" | sed 's/^[1-9][0-9]*$/1/')"
check "README Limits names effort" 1 "$(sed -n '/^## Limits/,/^## /p' "$root/README.md" | grep -c effort | sed 's/^[1-9][0-9]*$/1/')"
check "no model-routing outside the headroom README" 0 "$(grep -rl model-routing "$root/.." 2>/dev/null | grep -vcE 'headroom/(README.md|tests/test-hooks.sh)')"

check "plugin.json at 0.5.0" 0.5.0 "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$root/.claude-plugin/plugin.json")"
check "marketplace headroom entry at 0.5.0" 0.5.0 "$(python3 -c 'import json,sys;print([p["version"] for p in json.load(open(sys.argv[1]))["plugins"] if p["name"]=="headroom"][0])' "$root/../../.claude-plugin/marketplace.json")"

[ $fail -eq 0 ] && echo "all hook tests passed" || { echo "hook tests FAILED"; exit 1; }

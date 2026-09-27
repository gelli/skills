#!/bin/sh
# headroom SubagentStop hook. Two jobs, both from the same event:
#
# 1. Usage logging (2.1): for EVERY subagent stop, headroom or not, stream
#    agent_transcript_path and log one line with model, turn count, and
#    summed token usage, plus the size of last_assistant_message. This is
#    measurement, not enforcement, so it never blocks and logs even Explore
#    and other plugins' agents for comparison. SubagentStop can fire before
#    Claude Code has written the worker's final assistant entry to that
#    transcript (seen missing a whole final API call, and logging a partial
#    output_tokens snapshot), so the hook first waits, bounded, for it; see
#    hr_final_entry_written below. The line carries complete true/false
#    for whether that wait saw the final entry.
# 2. The report-length block: talks to the WORKER, not the main session.
#    When a headroom worker's own final report is long enough to defeat the
#    point of delegating (only the report, not the worker's intermediate
#    output, was ever meant to enter the main context), this blocks the
#    worker from stopping and asks it to resend a shorter report with a
#    report file. Thresholds: 60 lines, 8000 bytes. Limited to headroom's
#    own roles (agent_type starting with "headroom:"): Explore, other
#    plugins' agents and workflow agents are not headroom's to police (1.1).
#
# SubagentStop's additionalContext and decision:"block" both go to the
# SUBAGENT, never the parent session (a PostToolUse hook on Agent would be
# needed to reach the parent). The block is skipped when stop_hook_active is
# true (already looping once; do not loop forever); that guard resets each
# time the orchestrator sends the worker a new message. Phase 0's C1 check
# found last_assistant_message holds the worker's full report in both
# modes, including one delivered through a hand-back (SubagentHandback), so
# the block applies the same way to background and foreground workers.
#
# Parses hook input with jq, falling back to python3 (HEADROOM_PARSER=python3
# forces the python3 path for tests); with neither, or on unparseable input,
# it does nothing (no log, no block) and notes the gap on stderr. The
# transcript itself is streamed line by line, never slurped, and its own
# parse failure or a missing file only degrades the log line (transcript
# status "missing" or "unparsed", zero counts); it never blocks.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

LINE_LIMIT=60
BYTE_LIMIT=8000
TAIL_LINES=200
WAIT_BACKSTOP=5

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.agent_type // ""),
  (.agent_id // ""),
  (.agent_transcript_path // ""),
  (if .stop_hook_active then "true" else "false" end),
  (.last_assistant_message // "" | tojson),
  (.last_assistant_message // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("parsed")
print(d.get("agent_type") or "")
print(d.get("agent_id") or "")
print(d.get("agent_transcript_path") or "")
print("true" if d.get("stop_hook_active") else "false")
print(json.dumps(d.get("last_assistant_message") or ""))
print(d.get("last_assistant_message") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); usage logging and report-warning check skipped" >&2
  exit 0
fi

agent_type=$(printf '%s\n' "$fields" | sed -n 2p)
agent_id=$(printf '%s\n' "$fields" | sed -n 3p)
agent_transcript_path=$(printf '%s\n' "$fields" | sed -n 4p)
stop_hook_active=$(printf '%s\n' "$fields" | sed -n 5p)
# last_assistant_message twice: as a one-line JSON string for the
# final-entry match (fed to the parser as the first line of its stdin, so
# no shell step strips its trailing newlines and no argv/env size limit
# applies), and raw for the report-size check.
message_json=$(printf '%s\n' "$fields" | sed -n 6p)
message=$(printf '%s\n' "$fields" | sed -n '7,$p')

lines=$(printf '%s\n' "$message" | wc -l | tr -d '[:space:]')
bytes=$(printf '%s' "$message" | wc -c | tr -d '[:space:]')

# hr_transcript_stats <path> -- prints 7 lines: status (ok/missing/
# unparsed), model, turns, input_tokens, output_tokens,
# cache_read_input_tokens, cache_creation_input_tokens. Streams the file one
# line at a time (jq with fromjson? per line, or python3 reading line by
# line), so a huge transcript is never loaded whole. Assistant entries can
# repeat the same message.id across content-block lines; this dedups by
# keeping the last usage seen per id, then sums once per id. model is the
# last assistant model seen. Entries with message.model "<synthetic>" are
# skipped entirely (not counted as a turn, not dedup-stored): Claude Code
# writes that model with all-zero usage for entries like "No response
# requested." or "API Error: Connection lost...". Its zero usage would not
# change any sum, but counting it would still inflate turns by one and
# could leave "<synthetic>" as the logged model for a worker whose last
# entry is one of these. A missing/unreadable file, an
# unparseable one, or an unrecognised line never aborts the hook: they fall
# back to "missing" or "unparsed" with all-zero counts.
hr_transcript_stats() {
  hr_ts_path=$1
  if [ -z "$hr_ts_path" ] || [ ! -r "$hr_ts_path" ]; then
    printf 'missing\n\n0\n0\n0\n0\n0\n'
    return 0
  fi
  if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
    hr_ts_out=$(jq -Rn -r '
      reduce (inputs | fromjson? // empty) as $e (
        {"ids":{},"model":""};
        if ($e.type // "") == "assistant" and (($e.message.id // "") != "") and (($e.message.model // "") != "<synthetic>") then
          .ids[$e.message.id] = ($e.message.usage // {})
          | .model = ($e.message.model // .model)
        else . end
      )
      | "ok",
        (.model // ""),
        (.ids | length),
        ([.ids[].input_tokens // 0] | add // 0),
        ([.ids[].output_tokens // 0] | add // 0),
        ([.ids[].cache_read_input_tokens // 0] | add // 0),
        ([.ids[].cache_creation_input_tokens // 0] | add // 0)
    ' -- "$hr_ts_path" 2>/dev/null)
    hr_ts_rc=$?
  elif command -v python3 >/dev/null 2>&1; then
    hr_ts_out=$(python3 -c '
import json, sys
ids = {}
model = ""
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") == "assistant":
                msg = e.get("message") or {}
                if msg.get("model") == "<synthetic>":
                    continue
                mid = msg.get("id")
                if mid:
                    ids[mid] = msg.get("usage") or {}
                    m = msg.get("model")
                    if m:
                        model = m
except Exception:
    print("unparsed")
    print("")
    print(0); print(0); print(0); print(0); print(0)
    sys.exit(0)
print("ok")
print(model)
print(len(ids))
def s(k):
    return sum((u.get(k) or 0) for u in ids.values())
print(s("input_tokens"))
print(s("output_tokens"))
print(s("cache_read_input_tokens"))
print(s("cache_creation_input_tokens"))
' "$hr_ts_path" 2>/dev/null)
    hr_ts_rc=$?
  else
    echo "headroom: could not parse transcript (need jq or python3); usage counts skipped" >&2
    printf 'unparsed\n\n0\n0\n0\n0\n0\n'
    return 0
  fi
  if [ $hr_ts_rc -ne 0 ] || [ -z "$(printf '%s\n' "$hr_ts_out" | sed -n 1p)" ]; then
    printf 'unparsed\n\n0\n0\n0\n0\n0\n'
    return 0
  fi
  printf '%s\n' "$hr_ts_out"
}

# hr_final_entry_written <path> <message-json> -- returns 0 once the tail
# of <path> (last TAIL_LINES lines, cheap on any size of file) shows the
# worker's final assistant entry: the last assistant entry that carries
# text has text equal to last_assistant_message, and no user entry (a
# prompt, a tool_result, or a block reason) follows it. "<synthetic>"
# entries count here, since a worker can end on one. Non-zero otherwise,
# including when no parser is available.
hr_final_entry_written() {
  hr_fe_path=$1
  hr_fe_want=$2
  if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
    hr_fe_out=$({ printf '%s\n' "$hr_fe_want"; tail -n "$TAIL_LINES" "$hr_fe_path" 2>/dev/null; } | jq -Rn -r '
      (input | fromjson? // null) as $want
      | (reduce (inputs | fromjson? // empty | objects) as $e (
          {text: null, after: false};
          if ($e.type // "") == "assistant" then
            ([(($e.message // null) | if type == "object" then .content else null end)
              | if type == "array" then .[] else empty end | objects
              | select(.type == "text" and ((.text | type) == "string")) | .text]) as $t
            | if ($t | length) > 0 then .text = ($t | join("")) | .after = false else . end
          elif ($e.type // "") == "user" then .after = true
          else . end
        )) as $s
      | if ($want | type) == "string" and $want != "" and $s.text == $want and ($s.after | not) then "match" else "wait" end
    ' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    hr_fe_out=$({ printf '%s\n' "$hr_fe_want"; tail -n "$TAIL_LINES" "$hr_fe_path" 2>/dev/null; } | python3 -c '
import json, sys
try:
    want = json.loads(sys.stdin.readline())
except Exception:
    want = None
text = None
after = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if not isinstance(e, dict):
        continue
    t = e.get("type")
    if t == "user":
        after = True
    elif t == "assistant":
        msg = e.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        texts = [b["text"] for b in (content if isinstance(content, list) else [])
                 if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
        if texts:
            text = "".join(texts)
            after = False
print("match" if isinstance(want, str) and want != "" and text == want and not after else "wait")
' 2>/dev/null)
  else
    return 1
  fi
  [ "$hr_fe_out" = match ]
}

# Wait for the final entry before reading usage: re-check the tail every
# HEADROOM_WAIT_INTERVAL seconds (default 0.1), up to HEADROOM_WAIT_TRIES
# extra times (default 30), never past WAIT_BACKSTOP seconds of wall
# clock, well inside this hook's 15 s timeout with room left for the full
# stream below. No wait when there is no transcript or no message to
# match. On giving up, the counts are logged anyway with complete false.
complete=false
if [ -n "$agent_transcript_path" ] && [ -r "$agent_transcript_path" ] && [ "$message_json" != '""' ]; then
  tries=${HEADROOM_WAIT_TRIES:-30}
  case "$tries" in ''|*[!0-9]*) tries=30 ;; esac
  interval=${HEADROOM_WAIT_INTERVAL:-0.1}
  started=$(date +%s 2>/dev/null || echo 0)
  n=0
  while :; do
    if hr_final_entry_written "$agent_transcript_path" "$message_json"; then
      complete=true
      break
    fi
    [ "$n" -lt "$tries" ] || break
    now=$(date +%s 2>/dev/null || echo 0)
    [ $((now - started)) -lt "$WAIT_BACKSTOP" ] || break
    sleep "$interval" 2>/dev/null || sleep 1
    n=$((n + 1))
  done
fi

stats=$(hr_transcript_stats "$agent_transcript_path")
transcript_status=$(printf '%s\n' "$stats" | sed -n 1p)
model=$(printf '%s\n' "$stats" | sed -n 2p)
turns=$(printf '%s\n' "$stats" | sed -n 3p)
input_tokens=$(printf '%s\n' "$stats" | sed -n 4p)
output_tokens=$(printf '%s\n' "$stats" | sed -n 5p)
cache_read_input_tokens=$(printf '%s\n' "$stats" | sed -n 6p)
cache_creation_input_tokens=$(printf '%s\n' "$stats" | sed -n 7p)

# Log once per stop, for every agent type, before the headroom-only block
# check below (so it is logged even when the block fires).
hr_log_fields usage report-warning \
  agent_type "$agent_type" \
  agent_id "$agent_id" \
  model "$model" \
  turns "$turns" \
  input_tokens "$input_tokens" \
  output_tokens "$output_tokens" \
  cache_read_input_tokens "$cache_read_input_tokens" \
  cache_creation_input_tokens "$cache_creation_input_tokens" \
  report_bytes "$bytes" \
  report_lines "$lines" \
  transcript "$transcript_status" \
  complete "$complete" \
  stop_hook_active "$stop_hook_active"

# The report-length block is headroom's own guardrail on its own roles
# (1.1): Explore, other plugins' agents and workflow agents pass through
# silently here, and already-looping-once workers are never blocked twice.
case "$agent_type" in
  headroom:*) ;;
  *) exit 0 ;;
esac
[ "$stop_hook_active" != true ] || exit 0

if [ "$lines" -le "$LINE_LIMIT" ] && [ "$bytes" -le "$BYTE_LIMIT" ]; then
  exit 0
fi

# ~4 bytes per token.
kt=$((bytes / 4096))
[ "$kt" -gt 0 ] || kt=1
hr_log report report-warning "$agent_type report was $lines lines / $bytes bytes"
hr_block "headroom: your report is $lines lines (~${kt}k tokens). Move the detail into a report file in the scratch directory named in your brief and resend a report of at most 40 lines that gives its path."

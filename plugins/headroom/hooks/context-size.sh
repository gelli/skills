#!/bin/sh
# headroom Stop hook (plan 2.3): logs the main session's context size once
# per turn, the data Phase 4 needs for a context-growth curve. Only the main
# session fires Stop (a worker's own stop is SubagentStop, handled by
# report-warning.sh), so nothing here needs to check agent_type.
#
# Reads the hook input's transcript_path and looks only at its tail (`tail
# -n 200`), never the whole file: a transcript can run to hundreds of MB.
# Within that tail, it finds the last assistant entry that carries
# message.usage and whose message.model is not "<synthetic>" -- Claude Code
# writes that model with all-zero usage for entries like "No response
# requested." or "API Error: Connection lost...", and a turn that ends on
# one of those must not corrupt the context-growth curve with a zero -- and
# logs context_tokens = input_tokens +
# cache_read_input_tokens + cache_creation_input_tokens (the size of what
# the next turn's prompt re-sends), plus model. It deliberately does not sum
# across entries or dedup by message.id the way report-warning.sh does:
# repeated content-block lines share the same input/cache counts and differ
# only in output_tokens, which isn't part of context size, so only the last
# usage seen is used.
#
# Race with Claude Code's own transcript writes: Stop fires within a few
# hundred ms of the final assistant message, often before that entry is in
# the file, so a single read logs the previous API call's size (seen in 3
# of 3 sessions checked). The hook input carries last_assistant_message, so
# the tail is re-read every HEADROOM_WAIT_INTERVAL seconds (default 0.1),
# up to HEADROOM_WAIT_TRIES extra times (default 20) and never past a
# WAIT_BACKSTOP-second wall-clock cap, until the final entry is in: the
# last assistant entry in the tail that carries text has text equal to
# last_assistant_message, and no user entry (a prompt or a tool_result)
# follows it. The ordering check keeps a previous turn that ended on the
# same text ("Done.") from matching early. That entry may be "<synthetic>"
# for the match, though it is still skipped for the usage numbers. The
# line is logged either way, with complete true when the match was seen
# and false when it was not (timed out, or no message to match), so a
# stale point is flagged rather than lost.
#
# This hook is measurement only. It never blocks and never adds context for
# the model (no hr_add_context, hr_deny or hr_block call), so it prints
# nothing to stdout in any case. On any problem -- unparseable input, a
# missing or unreadable transcript, an unparseable tail, no usage found in
# the tail, or no jq/python3 available -- it notes the gap on stderr (where
# used) and exits 0 without logging.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$root/hooks/lib.sh"

TAIL_LINES=200
WAIT_BACKSTOP=3

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.transcript_path // ""),
  (.last_assistant_message // "" | tojson)
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("parsed")
print(d.get("transcript_path") or "")
print(json.dumps(d.get("last_assistant_message") or ""))
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); context-size logging skipped" >&2
  exit 0
fi

transcript_path=$(printf '%s\n' "$fields" | sed -n 2p)
# last_assistant_message as a one-line JSON string: it goes to the parser
# as the first line of its stdin, so no shell step strips its trailing
# newlines and no argv/env size limit applies.
message_json=$(printf '%s\n' "$fields" | sed -n 3p)
[ -n "$transcript_path" ] && [ -r "$transcript_path" ] || exit 0

if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
  parser=jq
elif command -v python3 >/dev/null 2>&1; then
  parser=python3
else
  echo "headroom: could not parse transcript (need jq or python3); context-size logging skipped" >&2
  exit 0
fi

# read_tail -- prints "ok", model, context_tokens, complete (true/false),
# or nothing (and non-zero from python3) when the tail has no usable usage.
read_tail() {
  if [ "$parser" = jq ]; then
    { printf '%s\n' "$message_json"; tail -n "$TAIL_LINES" "$transcript_path" 2>/dev/null; } | jq -Rn -r '
      (input | fromjson? // null) as $want
      | (reduce (inputs | fromjson? // empty | objects) as $e (
          {text: null, after: false, model: "", usage: null};
          (($e.message // null) | if type == "object" then . else {} end) as $m
          | if ($e.type // "") == "assistant" then
              ([$m.content | if type == "array" then .[] else empty end | objects
                | select(.type == "text" and ((.text | type) == "string")) | .text]) as $t
              | (if ($t | length) > 0 then .text = ($t | join("")) | .after = false else . end)
              | (if (($m.usage // null) | type) == "object" and (($m.model // "") != "<synthetic>") then
                   .model = ($m.model // .model // "") | .usage = $m.usage
                 else . end)
            elif ($e.type // "") == "user" then .after = true
            else . end
        )) as $s
      | if $s.usage == null then empty else
          "ok",
          ($s.model // ""),
          (($s.usage.input_tokens // 0) + ($s.usage.cache_read_input_tokens // 0) + ($s.usage.cache_creation_input_tokens // 0)),
          (if ($want | type) == "string" and $want != "" and $s.text == $want and ($s.after | not) then "true" else "false" end)
        end
    ' 2>/dev/null
  else
    { printf '%s\n' "$message_json"; tail -n "$TAIL_LINES" "$transcript_path" 2>/dev/null; } | python3 -c '
import json, sys
try:
    want = json.loads(sys.stdin.readline())
except Exception:
    want = None
model = ""
tokens = None
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
        continue
    if t != "assistant":
        continue
    msg = e.get("message")
    if not isinstance(msg, dict):
        msg = {}
    content = msg.get("content")
    texts = [b["text"] for b in (content if isinstance(content, list) else [])
             if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
    if texts:
        text = "".join(texts)
        after = False
    if msg.get("model") == "<synthetic>":
        continue
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        continue
    model = msg.get("model") or model
    tokens = (usage.get("input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0) + (usage.get("cache_creation_input_tokens") or 0)
if tokens is None:
    sys.exit(1)
print("ok")
print(model)
print(tokens)
print("true" if isinstance(want, str) and want != "" and text == want and not after else "false")
' 2>/dev/null
  fi
}

tries=${HEADROOM_WAIT_TRIES:-20}
case "$tries" in ''|*[!0-9]*) tries=20 ;; esac
interval=${HEADROOM_WAIT_INTERVAL:-0.1}
started=$(date +%s 2>/dev/null || echo 0)
n=0
while :; do
  stats=$(read_tail)
  rc=$?
  [ $rc -eq 0 ] && [ "$(printf '%s\n' "$stats" | sed -n 4p)" = true ] && break
  # Nothing to match against: waiting cannot confirm anything.
  [ "$message_json" != '""' ] || break
  [ "$n" -lt "$tries" ] || break
  now=$(date +%s 2>/dev/null || echo 0)
  [ $((now - started)) -lt "$WAIT_BACKSTOP" ] || break
  sleep "$interval" 2>/dev/null || sleep 1
  n=$((n + 1))
done

[ $rc -eq 0 ] && [ "$(printf '%s\n' "$stats" | sed -n 1p)" = ok ] || exit 0

model=$(printf '%s\n' "$stats" | sed -n 2p)
context_tokens=$(printf '%s\n' "$stats" | sed -n 3p)
complete=$(printf '%s\n' "$stats" | sed -n 4p)
[ "$complete" = true ] || complete=false

hr_log_fields context context-size model "$model" context_tokens "$context_tokens" complete "$complete"
exit 0

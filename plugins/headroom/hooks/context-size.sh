#!/bin/sh
# headroom Stop hook (plan 2.3): logs the main session's context size once
# per turn, the data Phase 4 needs for a context-growth curve. Only the main
# session fires Stop (a worker's own stop is SubagentStop, handled by
# report-warning.sh), so nothing here needs to check agent_type.
#
# Reads the hook input's transcript_path and looks only at its tail (`tail
# -n 200`), never the whole file: a transcript can run to hundreds of MB.
# Within that tail, it finds the last assistant entry that carries
# message.usage and logs context_tokens = input_tokens +
# cache_read_input_tokens + cache_creation_input_tokens (the size of what
# the next turn's prompt re-sends), plus model. It deliberately does not sum
# across entries or dedup by message.id the way report-warning.sh does:
# repeated content-block lines share the same input/cache counts and differ
# only in output_tokens, which isn't part of context size, so only the last
# usage seen is used.
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

hr_read_input
fields=$(hr_fields '
  "parsed",
  (.transcript_path // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("parsed")
print(d.get("transcript_path") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); context-size logging skipped" >&2
  exit 0
fi

transcript_path=$(printf '%s\n' "$fields" | sed -n 2p)
[ -n "$transcript_path" ] && [ -r "$transcript_path" ] || exit 0

if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
  stats=$(tail -n "$TAIL_LINES" "$transcript_path" 2>/dev/null | jq -Rn -r '
    (reduce (inputs | fromjson? // empty) as $e (
      {};
      if ($e.type // "") == "assistant" and (($e.message.usage // null) != null) then
        { model: ($e.message.model // .model // ""), usage: $e.message.usage }
      else . end
    )) as $last
    | if ($last | length) == 0 then empty else
        "ok",
        ($last.model // ""),
        (($last.usage.input_tokens // 0) + ($last.usage.cache_read_input_tokens // 0) + ($last.usage.cache_creation_input_tokens // 0))
      end
  ' 2>/dev/null)
  rc=$?
elif command -v python3 >/dev/null 2>&1; then
  stats=$(tail -n "$TAIL_LINES" "$transcript_path" 2>/dev/null | python3 -c '
import json, sys
model = ""
tokens = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("type") != "assistant":
        continue
    msg = e.get("message") or {}
    usage = msg.get("usage")
    if not usage:
        continue
    model = msg.get("model") or model
    tokens = (usage.get("input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0) + (usage.get("cache_creation_input_tokens") or 0)
if tokens is None:
    sys.exit(1)
print("ok")
print(model)
print(tokens)
' 2>/dev/null)
  rc=$?
else
  echo "headroom: could not parse transcript (need jq or python3); context-size logging skipped" >&2
  exit 0
fi

[ $rc -eq 0 ] && [ "$(printf '%s\n' "$stats" | sed -n 1p)" = ok ] || exit 0

model=$(printf '%s\n' "$stats" | sed -n 2p)
context_tokens=$(printf '%s\n' "$stats" | sed -n 3p)

hr_log_fields context context-size model "$model" context_tokens "$context_tokens"
exit 0

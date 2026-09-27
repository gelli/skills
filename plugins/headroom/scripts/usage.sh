#!/bin/sh
# headroom usage report (plan 2.5): summarises headroom.log.jsonl over a
# rolling window, matching the two quota windows users watch (5 hours, 7
# days), or "all" for the whole log.
#
# Usage: usage.sh [--window 5h|7d|all] [log-path]
#
# Log path: the first non-flag argument, else
# $CLAUDE_PLUGIN_DATA/headroom.log.jsonl, else the newest
# ~/.claude/plugins/data/headroom*/headroom.log.jsonl by mtime -- that glob
# is where a --plugin-dir session writes it, shared by every headroom
# loaded that way (Phase 0 results).
#
# Reads these event shapes, one JSON object per line, "ts" a unix second
# (see check-agent.sh, report-warning.sh, nudge.sh, block.sh,
# context-size.sh for how each is written):
#   allow/check-agent   -- an allowed Agent spawn: session_id, subagent_type,
#                           role, model, raised, isolation, run_in_background.
#   deny/check-agent    -- a refused spawn (no session_id: hr_log, not
#                           hr_log_fields).
#   usage/report-warning -- one line per worker stop: session_id, agent_type,
#                           agent_id, model, turns, input_tokens,
#                           output_tokens, cache_read_input_tokens,
#                           cache_creation_input_tokens, report_bytes.
#   nudge/nudge         -- a large main-session tool result: session_id,
#                           tool_name, bytes.
#   block/block         -- a hard_blocks refusal (no session_id).
#   context/context-size -- one line per main-session turn: session_id,
#                           model, context_tokens.
#
# Reports, all filtered to the window:
# - worker usage by agent_type and model: spawns, summed input/output/
#   cache-read/cache-write tokens, summed report bytes, and tokens per
#   report byte (total tokens / report bytes).
# - main-session context size, latest and max context_tokens per session.
# - counts of nudges, hard_blocks blocks, check-agent denies, and allowed
#   spawns that raised a role's model above its default.
# - sessions with a nudge but no allowed spawn: a sign delegation is being
#   suppressed rather than used.
#
# A worker can produce more than one SubagentStop: report-warning.sh's own
# comment notes stop_hook_active resets on every new message, so a worker
# blocked for a long report and resent, or resumed for a second round, logs
# a second "usage" line. hr_transcript_stats reads the whole transcript
# each time, so that second line's counts are already cumulative from the
# start of the transcript, not incremental. Summing every usage line per
# agent_id would double-count. Instead, usage lines are first deduped by
# agent_id, keeping only the last line seen for each id (append-only log,
# so "last in the file" is "last in time"); a missing agent_id is treated
# as its own worker rather than merged with other missing-id lines. Only
# then are the per-worker rows grouped and summed by agent_type and model,
# so "spawns" counts distinct workers, not stops. report_bytes uses the
# same last-line-wins value: a blocked first report never reached the main
# context, so only the final, actually-delivered report byte count counts.
#
# jq and python3 only group and sum integers, so the two paths agree
# exactly; the shell formats the report, including the one division
# (tokens per report byte), with awk, so that arithmetic exists once.
#
# Parses with jq, falling back to python3 (HEADROOM_PARSER=python3 forces
# the python3 path, used by tests). This is a standalone report, not a hook
# with a call to allow through, so with neither parser available it prints
# one line to stderr and exits 1.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

window=7d
path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --window)
      shift
      window=${1:-}
      [ $# -gt 0 ] && shift
      ;;
    --window=*)
      window=${1#--window=}
      shift
      ;;
    -h|--help)
      echo "Usage: usage.sh [--window 5h|7d|all] [log-path]"
      exit 0
      ;;
    *)
      [ -n "$path" ] || path=$1
      shift
      ;;
  esac
done

case "$window" in
  5h) window_seconds=18000; window_label="5h (last 5 hours)" ;;
  7d) window_seconds=604800; window_label="7d (last 7 days)" ;;
  all) window_seconds=""; window_label="all (no window)" ;;
  *)
    echo "usage.sh: unknown --window \"$window\" (want 5h, 7d, or all)" >&2
    exit 2
    ;;
esac

if [ -z "$path" ]; then
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -r "$CLAUDE_PLUGIN_DATA/headroom.log.jsonl" ]; then
    path="$CLAUDE_PLUGIN_DATA/headroom.log.jsonl"
  else
    path=$(ls -t "$HOME"/.claude/plugins/data/headroom*/headroom.log.jsonl 2>/dev/null | head -n 1)
  fi
fi

if [ -z "$path" ] || [ ! -r "$path" ]; then
  echo "usage.sh: no readable headroom.log.jsonl (checked the argument, \$CLAUDE_PLUGIN_DATA, and ~/.claude/plugins/data/headroom*/)" >&2
  exit 1
fi

now=$(date +%s 2>/dev/null || echo 0)
if [ -n "$window_seconds" ]; then
  cutoff=$((now - window_seconds))
else
  cutoff=0
fi

# Groups "usage" lines by agent_type+model and "context" lines by
# session_id, counts nudge/block/deny/raised-allow events, and tracks which
# sessions had a nudge vs an allowed spawn. Emits four tagged, tab-separated
# line shapes; field order must match the python3 branch below exactly.
#   WORKER<TAB>agent_type<TAB>model<TAB>spawns<TAB>input<TAB>output<TAB>cache_read<TAB>cache_write<TAB>report_bytes
#   CONTEXT<TAB>session_id<TAB>model<TAB>latest_tokens<TAB>max_tokens
#   COUNTS<TAB>nudges<TAB>blocks<TAB>denies<TAB>raises<TAB>allowed
#   SUPPRESSED<TAB>session_id
JQ_PROGRAM='
reduce (inputs | fromjson? // empty) as $e (
  {agents:{}, noid_seq:0, ctx:{}, nudges:0, blocks:0, denies:0, raises:0, allowed:0, nudge_sessions:{}, spawn_sessions:{}};
  ($e.ts // 0) as $ts
  | if $ts < $cutoff then .
    else
      ($e.event // "") as $ev
      | ($e.hook // "") as $hook
      | ($e.session_id // "") as $sid
      | if $ev == "usage" and $hook == "report-warning" then
          # Dedup by agent_id, last line wins: hr_transcript_stats sums the
          # whole worker transcript every stop, so a second stop for the
          # same worker already includes the counts of the first stop. A
          # missing agent_id becomes its own synthetic, never-repeated key.
          ($e.agent_id // "") as $aid
          | (if $aid != "" then $aid else "noid:\(.noid_seq)" end) as $key
          | .agents[$key] = {
              agent_type: ($e.agent_type // ""),
              model: ($e.model // ""),
              input: ($e.input_tokens // 0),
              output: ($e.output_tokens // 0),
              cache_read: ($e.cache_read_input_tokens // 0),
              cache_write: ($e.cache_creation_input_tokens // 0),
              report_bytes: ($e.report_bytes // 0)
            }
          | .noid_seq += (if $aid == "" then 1 else 0 end)
        elif $ev == "context" and $hook == "context-size" then
          ($e.model // "") as $m | ($e.context_tokens // 0) as $tok
          | (.ctx[$sid] // {model:$m, latest_ts:-1, latest_tokens:0, max_tokens:0}) as $c
          | .ctx[$sid] = {
              model: (if $ts >= $c.latest_ts then $m else $c.model end),
              latest_ts: (if $ts >= $c.latest_ts then $ts else $c.latest_ts end),
              latest_tokens: (if $ts >= $c.latest_ts then $tok else $c.latest_tokens end),
              max_tokens: (if $tok > $c.max_tokens then $tok else $c.max_tokens end)
            }
        elif $ev == "nudge" then
          .nudges += 1
          | (if $sid != "" then .nudge_sessions[$sid] = true else . end)
        elif $ev == "block" and $hook == "block" then
          .blocks += 1
        elif $ev == "deny" and $hook == "check-agent" then
          .denies += 1
        elif $ev == "allow" and $hook == "check-agent" then
          .allowed += 1
          | (if $e.raised == true then .raises += 1 else . end)
          | (if $sid != "" then .spawn_sessions[$sid] = true else . end)
        else .
        end
    end
) as $r
| ( reduce ($r.agents | to_entries[]) as $a (
      {};
      ($a.value.agent_type + "\u0001" + $a.value.model) as $key
      | (.[$key] // {spawns:0,input:0,output:0,cache_read:0,cache_write:0,report_bytes:0,agent_type:$a.value.agent_type,model:$a.value.model}) as $w
      | .[$key] = {
          spawns: ($w.spawns + 1),
          input: ($w.input + $a.value.input),
          output: ($w.output + $a.value.output),
          cache_read: ($w.cache_read + $a.value.cache_read),
          cache_write: ($w.cache_write + $a.value.cache_write),
          report_bytes: ($w.report_bytes + $a.value.report_bytes),
          agent_type: $a.value.agent_type, model: $a.value.model
        }
  )
  ) as $worker
| ( $worker | to_entries | sort_by([.value.agent_type, .value.model]) | .[] |
    ["WORKER", .value.agent_type, .value.model, .value.spawns, .value.input, .value.output, .value.cache_read, .value.cache_write, .value.report_bytes] | join("\t") ),
  ( $r.ctx | to_entries | sort_by(.key) | .[] |
    ["CONTEXT", .key, .value.model, .value.latest_tokens, .value.max_tokens] | join("\t") ),
  ( ["COUNTS", $r.nudges, $r.blocks, $r.denies, $r.raises, $r.allowed] | join("\t") ),
  ( (($r.nudge_sessions | keys) - ($r.spawn_sessions | keys)) | sort | .[] | ["SUPPRESSED", .] | join("\t") )
'

rc=1
raw=""
if [ "${HEADROOM_PARSER:-auto}" != python3 ] && command -v jq >/dev/null 2>&1; then
  raw=$(jq -Rn -r --argjson cutoff "$cutoff" "$JQ_PROGRAM" -- "$path" 2>/dev/null)
  rc=$?
elif command -v python3 >/dev/null 2>&1; then
  raw=$(python3 -c '
import json, sys

path, cutoff = sys.argv[1], int(sys.argv[2])
# Usage lines deduped by agent_id, last line wins (see the header comment
# and the matching jq branch): hr_transcript_stats sums the whole worker
# transcript on every stop, so later stops for the same worker already
# include earlier ones. A missing agent_id gets its own synthetic,
# never-repeated key.
agents = {}
noid_seq = 0
ctx = {}
nudges = blocks = denies = raises = allowed = 0
nudge_sessions = set()
spawn_sessions = set()

with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        ts = e.get("ts") or 0
        if ts < cutoff:
            continue
        ev = e.get("event") or ""
        hook = e.get("hook") or ""
        sid = e.get("session_id") or ""
        if ev == "usage" and hook == "report-warning":
            aid = e.get("agent_id") or ""
            if aid:
                key = aid
            else:
                key = "noid:%d" % noid_seq
                noid_seq += 1
            agents[key] = {
                "agent_type": e.get("agent_type") or "",
                "model": e.get("model") or "",
                "input": e.get("input_tokens") or 0,
                "output": e.get("output_tokens") or 0,
                "cache_read": e.get("cache_read_input_tokens") or 0,
                "cache_write": e.get("cache_creation_input_tokens") or 0,
                "report_bytes": e.get("report_bytes") or 0,
            }
        elif ev == "context" and hook == "context-size":
            m = e.get("model") or ""
            tok = e.get("context_tokens") or 0
            c = ctx.setdefault(sid, {"model": m, "latest_ts": -1, "latest_tokens": 0, "max_tokens": 0})
            if ts >= c["latest_ts"]:
                c["latest_ts"] = ts
                c["latest_tokens"] = tok
                c["model"] = m
            if tok > c["max_tokens"]:
                c["max_tokens"] = tok
        elif ev == "nudge":
            nudges += 1
            if sid:
                nudge_sessions.add(sid)
        elif ev == "block" and hook == "block":
            blocks += 1
        elif ev == "deny" and hook == "check-agent":
            denies += 1
        elif ev == "allow" and hook == "check-agent":
            allowed += 1
            if e.get("raised") is True:
                raises += 1
            if sid:
                spawn_sessions.add(sid)

worker = {}
for a in agents.values():
    key = (a["agent_type"], a["model"])
    w = worker.setdefault(key, {"spawns": 0, "input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "report_bytes": 0})
    w["spawns"] += 1
    w["input"] += a["input"]
    w["output"] += a["output"]
    w["cache_read"] += a["cache_read"]
    w["cache_write"] += a["cache_write"]
    w["report_bytes"] += a["report_bytes"]

for (at, m) in sorted(worker.keys()):
    w = worker[(at, m)]
    print("\t".join(str(x) for x in ["WORKER", at, m, w["spawns"], w["input"], w["output"], w["cache_read"], w["cache_write"], w["report_bytes"]]))

for sid in sorted(ctx.keys()):
    c = ctx[sid]
    print("\t".join(str(x) for x in ["CONTEXT", sid, c["model"], c["latest_tokens"], c["max_tokens"]]))

print("\t".join(str(x) for x in ["COUNTS", nudges, blocks, denies, raises, allowed]))

for sid in sorted(nudge_sessions - spawn_sessions):
    print("\t".join(["SUPPRESSED", sid]))
' "$path" "$cutoff" 2>/dev/null)
  rc=$?
else
  echo "usage.sh: need jq or python3 to read $path" >&2
  exit 1
fi

if [ $rc -ne 0 ]; then
  echo "usage.sh: failed to read or parse $path" >&2
  exit 1
fi

tab=$(printf '\t')

echo "headroom usage report -- window: $window_label"
echo "log: $path"
echo

echo "Worker usage by agent_type and model"
worker_lines=$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "WORKER"')
if [ -z "$worker_lines" ]; then
  echo "  (none)"
else
  printf '  %-22s %-20s %7s %9s %9s %11s %12s %13s %9s\n' \
    "agent_type" "model" "spawns" "input" "output" "cache_read" "cache_write" "report_bytes" "tok/byte"
  printf '%s\n' "$worker_lines" | while IFS="$tab" read -r _tag at model spawns input output cache_read cache_write report_bytes; do
    tot=$((input + output + cache_read + cache_write))
    tpb=$(LC_ALL=C awk -v t="$tot" -v b="$report_bytes" 'BEGIN { if (b > 0) printf "%.2f", t / b; else print "-" }')
    printf '  %-22s %-20s %7s %9s %9s %11s %12s %13s %9s\n' \
      "$at" "$model" "$spawns" "$input" "$output" "$cache_read" "$cache_write" "$report_bytes" "$tpb"
  done
fi
echo

echo "Main-session context size (latest / max context_tokens per session)"
ctx_lines=$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "CONTEXT"')
if [ -z "$ctx_lines" ]; then
  echo "  (none)"
else
  printf '  %-36s %-20s %10s %10s\n' "session" "model" "latest" "max"
  printf '%s\n' "$ctx_lines" | while IFS="$tab" read -r _tag sid model latest max; do
    printf '  %-36s %-20s %10s %10s\n' "$sid" "$model" "$latest" "$max"
  done
fi
echo

counts_line=$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "COUNTS"')
nudges=0; blocks=0; denies=0; raises=0; allowed=0
if [ -n "$counts_line" ]; then
  IFS="$tab" read -r _tag nudges blocks denies raises allowed <<EOF
$counts_line
EOF
fi
echo "Counts"
echo "  nudges: $nudges   blocks: $blocks   denies: $denies   raises: $raises (of $allowed allowed spawns)"
echo

echo "Sessions with nudges but zero allowed spawns (delegation may be suppressed)"
sup_lines=$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "SUPPRESSED"')
if [ -z "$sup_lines" ]; then
  echo "  (none)"
else
  printf '%s\n' "$sup_lines" | while IFS="$tab" read -r _tag sid; do
    echo "  $sid"
  done
fi

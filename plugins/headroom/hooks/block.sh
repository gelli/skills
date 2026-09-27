#!/bin/sh
# headroom PreToolUse hook for Bash|Grep: when hard_blocks is enabled,
# refuses test/build/lint/type-check runs and repo-wide searches in the main
# session, so the work goes to headroom:scout instead. Workers (agent_id
# present) are never blocked. A one-time or session-scoped override written
# by inline.sh, or env HEADROOM_BLOCKS=0, lifts the block. Glob is never
# blocked here: it is the cheapest lookup there is, and nudge.sh still
# covers a large Glob result.
#
# Bash: before splitting, heredoc bodies (lines between <<[-]['"]?WORD['"]?
# and a line equal to WORD) are dropped, and single/double-quoted string
# contents are removed (honouring backslash escapes: outside single quotes
# a backslash hides the next character from quote-state tracking and is
# dropped with it, e.g. \" inside a double-quoted string does not close it;
# inside single quotes backslash is a literal, per bash rules), so text
# inside a heredoc or a quoted string is never read as a command. $(, (, ),
# and backticks are then turned into segment boundaries too, so a
# subshell's or a command substitution's inner command (e.g.
# "(cd frontend && npm test)", "echo $(npm test)") becomes its own segment.
# What remains is split into segments on &&, ||, ;, |, and newlines.
# Leading env assignments and a leading "rtk " are stripped from each
# segment before matching; the built-in pattern (plus block_patterns) is
# matched against every segment. A built-in match gets today's message,
# which points at headroom:scout; a block_patterns match gets a neutral
# deny instead, since the user may have blocked it for reasons scout
# doesn't fix.
# Grep: repo-wide means no path, or path "." or CLAUDE_PROJECT_DIR (trailing
# slash tolerant), and no glob.
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
  (.session_id // ""),
  (.agent_id // ""),
  (.tool_name // ""),
  (.tool_input.path // ""),
  (.tool_input.glob // ""),
  (.tool_input.command // "")
' '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
t = d.get("tool_input") or {}
print("parsed")
print(d.get("session_id") or "")
print(d.get("agent_id") or "")
print(d.get("tool_name") or "")
print(t.get("path") or "")
print(t.get("glob") or "")
print(t.get("command") or "")
')
rc=$?
if [ $rc -ne 0 ] || [ "$(printf '%s\n' "$fields" | sed -n 1p)" != parsed ]; then
  echo "headroom: could not parse hook input (need jq or python3); block check skipped" >&2
  exit 0
fi

session_id=$(printf '%s\n' "$fields" | sed -n 2p)
agent_id=$(printf '%s\n' "$fields" | sed -n 3p)
tool_name=$(printf '%s\n' "$fields" | sed -n 4p)
path=$(printf '%s\n' "$fields" | sed -n 5p)
glob=$(printf '%s\n' "$fields" | sed -n 6p)
# command can be multi-line, so it is always the last field extracted.
command=$(printf '%s\n' "$fields" | sed -n '7,$p')
# Byte size of the command text that triggered (or would trigger) a block:
# there is no tool output yet to measure at PreToolUse, so this is the
# closest stand-in (plan 2.4). 0 for Grep, which has no command field.
command_bytes=$(printf '%s' "$command" | wc -c | tr -d '[:space:]')

# Workers are never blocked.
[ -z "$agent_id" ] || exit 0

# Off by default; env kill switch overrides everything. The exact string
# encoding of a boolean userConfig value in CLAUDE_PLUGIN_OPTION_* is not
# documented, so both "true" and "1" are accepted.
case "${CLAUDE_PLUGIN_OPTION_HARD_BLOCKS:-false}" in
  true|1) : ;;
  *) exit 0 ;;
esac
[ "${HEADROOM_BLOCKS:-1}" != 0 ] || exit 0

block_patterns="${CLAUDE_PLUGIN_OPTION_BLOCK_PATTERNS:-}"

builtin_pattern='^(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(test|build|lint|typecheck|type-check|check)(:[^[:space:]]*)?([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^npx[[:space:]]+(jest|vitest|tsc|eslint)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^(jest|vitest)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^pytest([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^python[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^tox([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^cargo[[:space:]]+(test|build|check|clippy)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^go[[:space:]]+(test|build|vet)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^tsc([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^eslint([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^ruff[[:space:]]+check([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^mypy([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^mvn([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^(gradle|\./gradlew)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^make[[:space:]]+(test|build|lint|check)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^swift[[:space:]]+(test|build)([[:space:]]|$)'
builtin_pattern="$builtin_pattern"'|^dotnet[[:space:]]+(test|build)([[:space:]]|$)'

strip_segment() {
  seg=$1
  seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  while printf '%s' "$seg" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]'; do
    seg=$(printf '%s' "$seg" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
  done
  case "$seg" in
    "rtk "*) seg=${seg#rtk } ;;
  esac
  printf '%s' "$seg"
}

# strip_heredocs: drops lines between a heredoc marker (<<, optional -,
# optional quote, WORD, optional matching quote) and a line equal to WORD,
# so heredoc body text is never read as a command.
strip_heredocs() {
  awk '
    BEGIN { in_hd = 0; delim = "" }
    {
      line = $0
      if (in_hd) {
        if (line == delim) { in_hd = 0; delim = "" }
        next
      }
      if (match(line, /<<-?[\047\042]?[A-Za-z_][A-Za-z0-9_]*[\047\042]?/)) {
        m = substr(line, RSTART, RLENGTH)
        sub(/^<</, "", m)
        sub(/^-/, "", m)
        gsub(/[\047\042]/, "", m)
        delim = m
        in_hd = 1
      }
      print line
    }
  '
}

# strip_quotes: removes the contents of single- and double-quoted strings
# (keeping the quote characters themselves), so text like "a; npm test; b"
# is never split or matched as a command. Quote state persists across lines
# so a genuine multi-line quoted string is stripped in full. Outside single
# quotes, a backslash hides the character after it from quote-state
# tracking and both are dropped, so an escaped quote (e.g. \" inside a
# double-quoted string) never closes it; inside single quotes backslash is
# a literal, ordinary (dropped) content character, per bash rules.
strip_quotes() {
  awk '
    BEGIN { state = 0; esc = 0 }
    {
      line = $0
      out = ""
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (state == 1) {
          if (c == "\047") { state = 0; out = out c }
          continue
        }
        if (esc) { esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (state == 0) {
          if (c == "\047") { state = 1; out = out c }
          else if (c == "\042") { state = 2; out = out c }
          else { out = out c }
        } else {
          if (c == "\042") { state = 0; out = out c }
        }
      }
      print out
    }
  '
}

# strip_subshells: turns $(, (, ), and backtick into segment boundaries (a
# newline), so a subshell's or a command substitution's inner command
# becomes its own segment and is matched like any other segment, e.g.
# "(cd frontend && npm test)", "(npm test)", "echo $(npm test)",
# "echo `npm test`", "RESULT=$(npm test)". Must run after strip_quotes, so
# parens/backticks that were only quoted text (already dropped by
# strip_quotes) are never mistaken for boundaries, e.g. echo "(npm test)".
strip_subshells() {
  sed -E 's/\$\(/\
/g' | sed -E 's/[()`]/\
/g'
}

matched_seg=""
matched_source=""
if [ "$tool_name" = Bash ] && [ -n "$command" ]; then
  scrubbed=$(printf '%s' "$command" | strip_heredocs | strip_quotes | strip_subshells)
  segments=$(printf '%s' "$scrubbed" | sed -E 's/(&&|\|\||;|\|)/\
/g')
  while IFS= read -r seg || [ -n "$seg" ]; do
    seg=$(strip_segment "$seg")
    [ -n "$seg" ] || continue
    if printf '%s' "$seg" | grep -Eq "$builtin_pattern"; then
      matched_seg=$seg
      matched_source=builtin
      break
    fi
    if [ -n "$block_patterns" ] && printf '%s' "$seg" | grep -Eq "$block_patterns"; then
      matched_seg=$seg
      matched_source=user
      break
    fi
  done <<EOF
$segments
EOF
fi

repo_wide=0
if [ "$tool_name" = Grep ]; then
  proj="${CLAUDE_PROJECT_DIR:-}"
  proj=${proj%/}
  p=${path%/}
  if [ -z "$path" ] || [ "$p" = "." ] || { [ -n "$proj" ] && [ "$p" = "$proj" ]; }; then
    [ -z "$glob" ] && repo_wide=1
  fi
fi

# Nothing to deny: leave any inline override file untouched (a benign call
# must not consume a one-time override meant for a later, blocked call).
if [ -z "$matched_seg" ] && [ "$repo_wide" != 1 ]; then
  exit 0
fi

# About to deny: check the inline override written by inline.sh.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -n "$session_id" ]; then
  override_file="$CLAUDE_PLUGIN_DATA/inline/$session_id"
  if [ -r "$override_file" ]; then
    scope=$(cat "$override_file" 2>/dev/null || true)
    case "$scope" in
      *session*)
        hr_log override block "session inline override active for $tool_name"
        exit 0
        ;;
      *once*)
        rm -f "$override_file" 2>/dev/null || true
        hr_log override block "one-time inline override consumed for $tool_name"
        exit 0
        ;;
    esac
  fi
fi

if [ -n "$matched_seg" ]; then
  hr_log_fields block block tool_name "$tool_name" bytes "$command_bytes" detail "$matched_seg"
  if [ "$matched_source" = user ]; then
    hr_deny "headroom: \"$matched_seg\" matched a user block_patterns entry; hard_blocks is on for the main session. Ask the user to run /headroom:inline (this call only) or /headroom:inline session to lift it."
  else
    hr_deny "headroom: \"$matched_seg\" is delegable test/build/lint/type-check work; hard_blocks is on for the main session. Delegate to headroom:scout, or ask the user to run /headroom:inline (this call only) or /headroom:inline session."
  fi
  exit 0
fi

hr_log_fields block block tool_name "$tool_name" bytes "$command_bytes" detail "repo-wide search"
hr_deny "headroom: a repo-wide $tool_name is delegable work; hard_blocks is on for the main session. Delegate to headroom:scout, or ask the user to run /headroom:inline (this call only) or /headroom:inline session."
exit 0

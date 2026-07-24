#!/usr/bin/env bash
# Run with: ./tests/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
BIN=$HERE/../bin
DEAD_PID=4194303   # above /proc/sys/kernel/pid_max default, can never be live

printf 'claude-sessions: liveness\n'

root=$(new_root)
mk_session "$root" "$$" interactive "api refactor" busy 120000
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "live interactive session is listed" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "name is carried through" \
  "$(jq -r '.sessions[0].name' <<<"$out")" "api refactor"
check "kind is normalized to interactive" \
  "$(jq -r '.sessions[0].kind' <<<"$out")" "interactive"
check "idle_ms is roughly the fixture age" \
  "$(jq -r '.sessions[0].idle_ms | . >= 120000 and . < 130000' <<<"$out")" "true"
check "host is reported" \
  "$(jq -r '.host == "" | not' <<<"$out")" "true"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$DEAD_PID" interactive "ghost" idle 1000
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "dead pid is skipped" "$(jq -r '.sessions | length' <<<"$out")" "0"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" interactive "impostor" idle 1000 "" 99999999
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "pid reuse is skipped" "$(jq -r '.sessions | length' <<<"$out")" "0"
rm -rf "$root"

root=$(new_root)
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "empty registry yields empty array" "$(jq -r '.sessions | length' <<<"$out")" "0"
check "empty registry is valid JSON with all keys" \
  "$(jq -r 'has("host") and has("generated_at") and has("degraded") and has("unreadable")' <<<"$out")" "true"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" interactive "good" busy 1000
printf 'not json at all' >"$root/sessions/777777.json"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "malformed file does not sink its siblings" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "malformed file is counted" "$(jq -r '.unreadable' <<<"$out")" "1"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" interactive "$(printf 'a<b>c\033[31md')" busy 1000
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "name is stripped of control chars and markup-escaped" \
  "$(jq -r '.sessions[0].name' <<<"$out")" "a&lt;b&gt;c[31md"
rm -rf "$root"

# A file that PASSES the bash pre-filter (real "pid":N / "procStart":"N" for
# a live pid) but is truncated/invalid JSON must not sink the whole batch:
# only the bad file should be lost, not every good session alongside it.
root=$(new_root)
mk_session "$root" "$$" interactive "good" busy 1000
sleep 60 &
corrupt_pid=$!
corrupt_start=$(proc_start_of "$corrupt_pid")
printf '{"pid":%d,"sessionId":"s-%d","cwd":"/home/u/projects/demo","startedAt":1,"procStart":"%s","version":"2.1.219","kind":"interactive","entrypoint":"cli","name":"trunc' \
  "$corrupt_pid" "$corrupt_pid" "$corrupt_start" >"$root/sessions/$corrupt_pid.json"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "good session survives a truncated sibling that passes the pre-filter" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "truncated sibling is counted as unreadable" "$(jq -r '.unreadable' <<<"$out")" "1"
kill "$corrupt_pid" 2>/dev/null
wait "$corrupt_pid" 2>/dev/null
rm -rf "$root"

summary

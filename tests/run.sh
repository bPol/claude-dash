#!/usr/bin/env bash
# Run with: ./tests/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
BIN=$HERE/../bin
DEAD_PID=4194303   # above /proc/sys/kernel/pid_max default, can never be live

# Hermetic by default: no test may reach the real `claude` binary or the real
# shared arbitration stamp (${XDG_RUNTIME_DIR}/claude-dash-arbitrated), even
# one that forgets to override. An empty/all-dead fixture legitimately
# triggers Task 3's arbitration in production, but in tests that must land on
# a CLI that can't exist and a stamp confined to this run's own temp dir, not
# the machine's real CLI or shared stamp. Tests that deliberately exercise
# degraded mode override both explicitly on the command line, which take
# precedence over these exports.
RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-run.XXXXXX")
trap 'rm -rf "$RUN_TMP"' EXIT
export CLAUDE_DASH_CLI="$RUN_TMP/no-such-claude"
export CLAUDE_DASH_STAMP="$RUN_TMP/stamp"

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

printf '\nclaude-sessions: background state and ordering\n'

root=$(new_root)
mk_session "$root" "$$" bg "typo clarification" idle 360000 j-blocked
mk_job "$root" j-blocked blocked "did you mean \`exit\` or \`edit\`?"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "background state is merged from the job file" \
  "$(jq -r '.sessions[0].state' <<<"$out")" "blocked"
# shellcheck disable=SC2016 # single-quoted on purpose: literal backticks, not command substitution
check "needs text is merged" \
  "$(jq -r '.sessions[0].needs' <<<"$out")" 'did you mean `exit` or `edit`?'
check "blocked agent is not finished" \
  "$(jq -r '.sessions[0].finished' <<<"$out")" "false"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" bg "sales" idle 950400000 j-done
# shellcheck disable=SC1010 # "done" here is the job state arg, not the loop keyword
mk_job "$root" j-done done
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "done agent is marked finished" \
  "$(jq -r '.sessions[0].finished' <<<"$out")" "true"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" bg "orphan" idle 1000 j-missing
mkdir -p "$root/jobs/j-missing"     # job dir with no state.json, as seen live
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "job dir without state.json still lists the session" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "missing state.json leaves state null" \
  "$(jq -r '.sessions[0].state' <<<"$out")" "null"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" bg "blocked agent" idle 5000 j-b
mk_job "$root" j-b blocked "answer me"
mk_session "$root" 1 interactive "idle interactive" idle 5000
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "interactive sorts above background" \
  "$(jq -r '.sessions[0].kind' <<<"$out")" "interactive"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" interactive "stale idle" idle 600000
mk_session "$root" 1 interactive "fresh idle" idle 5000
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "most recently active sorts first" \
  "$(jq -r '.sessions[0].name' <<<"$out")" "fresh idle"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" bg "markup asker" idle 1000 j-markup
mk_job "$root" j-markup blocked "$(printf 'use <div> or <section>?\033[0m')"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "needs text is markup-escaped and stripped of control chars" \
  "$(jq -r '.sessions[0].needs' <<<"$out")" "use &lt;div&gt; or &lt;section&gt;?[0m"
rm -rf "$root"

root=$(new_root)
mk_session "$root" "$$" interactive "in a shell command" shell 1000
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "status shell counts as working" \
  "$(jq -r '.sessions[0].working' <<<"$out")" "true"
check "status shell is still reported literally" \
  "$(jq -r '.sessions[0].status' <<<"$out")" "shell"
rm -rf "$root"

printf '\nclaude-sessions: degraded mode\n'

# A stub standing in for `claude agents --json`.
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-stub.XXXXXX")
cat >"$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] || exit 1
cat <<'JSON'
[{"pid":490201,"cwd":"/home/u/projects/demo","kind":"interactive",
  "startedAt":1784794917430,"sessionId":"x","name":"from cli","status":"busy"}]
JSON
STUB
chmod +x "$stub_dir/claude"

root=$(new_root)
rm -rf "$root/sessions"        # registry gone entirely
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=$stub_dir/claude \
      CLAUDE_DASH_STAMP=$root/stamp "$BIN/claude-sessions")
check "missing registry falls back to the CLI" \
  "$(jq -r '.sessions[0].name' <<<"$out")" "from cli"
check "fallback sets degraded" "$(jq -r '.degraded' <<<"$out")" "true"
check "fallback leaves idle_ms null" "$(jq -r '.sessions[0].idle_ms' <<<"$out")" "null"
rm -rf "$root"

root=$(new_root)                # registry present, parses, but empty
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=$stub_dir/claude \
      CLAUDE_DASH_STAMP=$root/stamp "$BIN/claude-sessions")
check "empty registry contradicted by the CLI goes degraded" \
  "$(jq -r '.degraded' <<<"$out")" "true"
check "arbitration writes a stamp file" \
  "$([[ -f $root/stamp ]] && echo yes || echo no)" "yes"
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=/nonexistent/claude \
      CLAUDE_DASH_STAMP=$root/stamp "$BIN/claude-sessions")
check "fresh stamp suppresses a second arbitration" \
  "$(jq -r '.degraded' <<<"$out")" "false"
rm -rf "$root"

root=$(new_root)                # registry empty and the CLI agrees
cat >"$stub_dir/claude-empty" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
STUB
chmod +x "$stub_dir/claude-empty"
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=$stub_dir/claude-empty \
      CLAUDE_DASH_STAMP=$root/stamp "$BIN/claude-sessions")
check "genuine zero is not degraded" "$(jq -r '.degraded' <<<"$out")" "false"
check "genuine zero has no sessions" "$(jq -r '.sessions | length' <<<"$out")" "0"
rm -rf "$root"

root=$(new_root)                # CLI itself broken, registry gone
rm -rf "$root/sessions"
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=/nonexistent/claude \
      CLAUDE_DASH_STAMP=$root/stamp "$BIN/claude-sessions")
check "both sources failing still emits valid JSON" \
  "$(jq -r '.sessions | length' <<<"$out")" "0"
rm -rf "$root"

# A counting stub: records one line per invocation, so the rate limit on
# Path 1 (registry entirely absent) can be asserted by invocation count, not
# just by output shape.
cat >"$stub_dir/claude-counting" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >>"$COUNT_FILE"
[[ "$1" == "agents" ]] || exit 1
cat <<'JSON'
[{"pid":490203,"cwd":"/home/u/projects/demo","kind":"interactive",
  "startedAt":1784794917430,"sessionId":"z","name":"counted","status":"busy"}]
JSON
STUB
chmod +x "$stub_dir/claude-counting"

root=$(new_root)
rm -rf "$root/sessions"          # registry gone entirely, before either call
count_file=$root/call-count
: >"$count_file"
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=$stub_dir/claude-counting \
      CLAUDE_DASH_STAMP=$root/stamp COUNT_FILE=$count_file "$BIN/claude-sessions")
check "missing registry invokes the CLI once and stays degraded" \
  "$(jq -r '.degraded' <<<"$out")" "true"
check "missing registry: first call invokes the CLI exactly once" \
  "$(wc -l <"$count_file" | tr -d ' ')" "1"
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=$stub_dir/claude-counting \
      CLAUDE_DASH_STAMP=$root/stamp COUNT_FILE=$count_file "$BIN/claude-sessions")
check "missing registry: second call within the rate-limit window does not invoke the CLI again" \
  "$(wc -l <"$count_file" | tr -d ' ')" "1"
check "missing registry: rate-limited second call still reports degraded" \
  "$(jq -r '.degraded' <<<"$out")" "true"
check "missing registry: rate-limited second call has no cached sessions" \
  "$(jq -r '.sessions | length' <<<"$out")" "0"
rm -rf "$root"

# A stub returning agent-authored text with markup and a control character
# (BEL), mirroring the reviewer's `<b>evil&bad</b>` example: cli_sessions()
# must sanitise it the same way the registry path does.
cat >"$stub_dir/claude-unsafe" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "agents" ]] || exit 1
name=$'<b>evil&bad\a</b>'
printf '[{"pid":490204,"cwd":"/home/u/projects/demo","kind":"interactive","startedAt":1784794917430,"sessionId":"w","name":%s,"status":"busy"}]\n' \
  "$(printf '%s' "$name" | jq -Rs .)"
STUB
chmod +x "$stub_dir/claude-unsafe"

root=$(new_root)
rm -rf "$root/sessions"          # registry gone entirely
out=$(CLAUDE_DASH_ROOT=$root CLAUDE_DASH_CLI=$stub_dir/claude-unsafe \
      CLAUDE_DASH_STAMP=$root/stamp "$BIN/claude-sessions")
check "CLI-supplied name with markup and a control char is sanitised" \
  "$(jq -r '.sessions[0].name' <<<"$out")" '&lt;b&gt;evil&amp;bad&lt;/b&gt;'
rm -rf "$root"

rm -rf "$stub_dir"

summary

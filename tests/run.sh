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

printf '\nclaude-sessions: orphan job rows (background process already exited)\n'

# Shape (b): the process has exited, so there is no sessions/<pid>.json at
# all -- only jobs/<id>/state.json survives. This is the case the whole tool
# exists for: an agent blocked and waiting on the user that would otherwise
# be completely invisible.
root=$(new_root)
mk_orphan_job "$root" j-orphan-blocked blocked "typo clarification" \
  "/home/u/projects/demo" "did you mean \`exit\` or \`edit\`?"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "orphan blocked job appears as a row" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "orphan blocked row has no pid" \
  "$(jq -r '.sessions[0].pid' <<<"$out")" "null"
check "orphan blocked row carries its name" \
  "$(jq -r '.sessions[0].name' <<<"$out")" "typo clarification"
check "orphan blocked row carries its cwd" \
  "$(jq -r '.sessions[0].cwd' <<<"$out")" "/home/u/projects/demo"
check "orphan blocked row state is blocked" \
  "$(jq -r '.sessions[0].state' <<<"$out")" "blocked"
# shellcheck disable=SC2016 # single-quoted on purpose: literal backticks, not command substitution
check "orphan blocked row carries its needs text" \
  "$(jq -r '.sessions[0].needs' <<<"$out")" 'did you mean `exit` or `edit`?'
check "orphan blocked row is not finished" \
  "$(jq -r '.sessions[0].finished' <<<"$out")" "false"
check "orphan blocked row is not working" \
  "$(jq -r '.sessions[0].working' <<<"$out")" "false"
check "orphan blocked job_id is the job directory name" \
  "$(jq -r '.sessions[0].job_id' <<<"$out")" "j-orphan-blocked"
rm -rf "$root"

root=$(new_root)
mk_orphan_job "$root" j-orphan-done done "sales" "/home/u/projects/other"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "orphan done job appears as a row" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "orphan done job is marked finished" \
  "$(jq -r '.sessions[0].finished' <<<"$out")" "true"
check "orphan done job is not working" \
  "$(jq -r '.sessions[0].working' <<<"$out")" "false"
rm -rf "$root"

# The same job id has both a live session file AND a job directory (the
# common in-progress case): the session-derived row wins and no duplicate
# appears.
root=$(new_root)
mk_session "$root" "$$" bg "typo clarification" idle 5000 j-shared
mk_job "$root" j-shared blocked "answer me"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "job covered by a live session yields exactly one row" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "the surviving row is the session-derived one (has a pid)" \
  "$(jq -r '.sessions[0].pid' <<<"$out")" "$$"
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

printf '\nclaude-dash-badge\n'

producer_stub() {   # producer_stub SESSIONS_JSON -> path to a stub producer
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-prod.XXXXXX")
  { printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n'
    jq -n --argjson s "$1" '{host:"testbox",generated_at:0,degraded:false,unreadable:0,sessions:$s}'
    printf 'JSON\n'
  } >"$d/producer"
  chmod +x "$d/producer"
  printf '%s' "$d/producer"
}

p=$(producer_stub '[
  {"kind":"interactive","pid":1,"name":"api refactor","cwd":"/home/u/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":120000,"job_id":null,"finished":false},
  {"kind":"interactive","pid":2,"name":"animation","cwd":"/home/u/x","status":"idle","working":false,"state":null,"needs":null,"idle_ms":600000,"job_id":null,"finished":false},
  {"kind":"bg","pid":3,"name":"typo clarification","cwd":"/home/u/x","status":"idle","working":false,"state":"blocked","needs":"exit or edit?","idle_ms":360000,"job_id":"j","finished":false},
  {"kind":"bg","pid":4,"name":"sales","cwd":"/home/u/x","status":"idle","working":false,"state":"done","needs":null,"idle_ms":950400000,"job_id":"k","finished":true}]')
out=$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge")
check "badge counts are busy/blocked/idle over unfinished rows" \
  "$(jq -r '.text' <<<"$out")" "1▸1▸1"
check "blocked sets the alert class" "$(jq -r '.class' <<<"$out")" "alert"
check "tooltip leads with the hostname" \
  "$(jq -r '.tooltip | split("\n")[0]' <<<"$out")" "testbox"
check "tooltip mentions the blocked agent" \
  "$(jq -r '.tooltip | contains("typo clarification")' <<<"$out")" "true"
rm -rf "$(dirname "$p")"

p=$(producer_stub '[{"kind":"interactive","pid":1,"name":"n","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
check "busy without blocked is the active class" \
  "$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge" | jq -r '.class')" "active"
rm -rf "$(dirname "$p")"

p=$(producer_stub '[{"kind":"interactive","pid":1,"name":"n","cwd":"/x","status":"shell","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
check "a session in a shell command counts as busy, not idle" \
  "$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge" | jq -r '.text')" "1▸0▸0"
rm -rf "$(dirname "$p")"

p=$(producer_stub '[{"kind":"interactive","pid":1,"name":"n","cwd":"/x","status":"idle","working":false,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
check "all idle is the quiet class" \
  "$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge" | jq -r '.class')" "quiet"
rm -rf "$(dirname "$p")"

out=$(CLAUDE_DASH_PRODUCER=/nonexistent/producer "$BIN/claude-dash-badge")
check "producer failure yields the error class" "$(jq -r '.class' <<<"$out")" "error"
check "producer failure still renders a glyph, never a blank" \
  "$(jq -r '.text' <<<"$out")" "?"

printf '\nclaude-dash board\n'

p=$(producer_stub '[
  {"kind":"interactive","pid":1,"name":"api refactor","cwd":"/home/u/src/api","status":"busy","working":true,"state":null,"needs":null,"idle_ms":120000,"job_id":null,"finished":false},
  {"kind":"bg","pid":3,"name":"typo clarification","cwd":"/home/u/src/api","status":"idle","working":false,"state":"blocked","needs":"did you mean exit or edit?","idle_ms":360000,"job_id":"j","finished":false},
  {"kind":"bg","pid":4,"name":"sales","cwd":"/home/u/src/ops","status":"idle","working":false,"state":"done","needs":null,"idle_ms":950400000,"job_id":"k","finished":true}]')
frame=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)

check "header carries the hostname" \
  "$(grep -c 'claude sessions · testbox' <<<"$frame")" "1"
check "interactive section is present" "$(grep -c '^ INTERACTIVE' <<<"$frame")" "1"
check "background section is present" "$(grep -c '^ BACKGROUND' <<<"$frame")" "1"
check "live rows are shown" "$(grep -c 'api refactor' <<<"$frame")" "1"
check "blocked row shows what it needs" \
  "$(grep -c 'did you mean exit or edit?' <<<"$frame")" "1"
check "finished agent is collapsed, not listed as a row" \
  "$(grep -c '1 finished' <<<"$frame")" "1"
check "ages are humanised" "$(grep -c '2m' <<<"$frame")" "1"
check "no frame line exceeds the terminal width" \
  "$(awk 'length > 100' <<<"$frame" | wc -l)" "0"
rm -rf "$(dirname "$p")"

p=$(producer_stub '[]')
frame=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)
check "empty board says so explicitly" "$(grep -c 'no sessions running' <<<"$frame")" "1"
rm -rf "$(dirname "$p")"

d=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-prod.XXXXXX")
{ printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n'
  jq -n '{host:"testbox",generated_at:0,degraded:true,unreadable:2,sessions:[]}'
  printf 'JSON\n'; } >"$d/producer"
chmod +x "$d/producer"
frame=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$d/producer "$BIN/claude-dash" --once)
check "degraded mode is announced in the header" \
  "$(grep -c 'degraded (CLI fallback)' <<<"$frame")" "1"
check "unreadable files are announced" "$(grep -c '2 unreadable' <<<"$frame")" "1"
rm -rf "$d"

# Without a terminal on stdin, `read -t` returns instantly. If the loop used it
# anyway it would spin as fast as the CPU allows. Run it headless for 1s with a
# 0.2s interval: a sleeping loop paints ~5 frames, a spinning one paints
# thousands. The bound is deliberately loose so a slow machine does not flake.
p=$(producer_stub '[]')
frames=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$p CLAUDE_DASH_INTERVAL=1 \
         timeout 2 "$BIN/claude-dash" </dev/null 2>/dev/null | tr -cd 'q' | wc -c)
check "non-tty loop sleeps instead of spinning" \
  "$([[ $frames -lt 50 ]] && echo bounded || echo spinning)" "bounded"
rm -rf "$(dirname "$p")"

printf '\nclaude-dash: pidfile cleanup with multiple instances\n'

# Test that cleanup only removes pidfile if it contains this process's PID.
# Bug: the first board to exit unconditionally removes the pidfile, even if
# it now contains a different (still-running) board's PID.
test_pidfile=$(mktemp "${TMPDIR:-/tmp}/claude-dash-test-pid.XXXXXX")
p=$(producer_stub '[]')

# Start first board in background, let it write its pidfile
CLAUDE_DASH_PIDFILE="$test_pidfile" CLAUDE_DASH_PRODUCER=$p timeout 10 "$BIN/claude-dash" </dev/null >/dev/null 2>&1 &
job_a=$!
sleep 0.3  # let it write the pidfile

pid_a=$(cat "$test_pidfile" 2>/dev/null || printf '')
check "first board wrote to pidfile" "$([[ -n $pid_a ]] && printf yes || printf no)" "yes"

# Start second board in background, let it overwrite pidfile
CLAUDE_DASH_PIDFILE="$test_pidfile" CLAUDE_DASH_PRODUCER=$p timeout 10 "$BIN/claude-dash" </dev/null >/dev/null 2>&1 &
job_b=$!
sleep 0.3  # let it write the pidfile, overwriting the first

pid_b=$(cat "$test_pidfile" 2>/dev/null || printf '')
check "second board overwrote pidfile" "$([[ "$pid_b" != "$pid_a" ]] && printf yes || printf no)" "yes"

# Kill the first board
kill "$job_a" 2>/dev/null || true
wait "$job_a" 2>/dev/null || true
sleep 0.2

# Check if pidfile still exists and still contains second board's pid
pid_after_kill=$(cat "$test_pidfile" 2>/dev/null || printf '')
check "pidfile still exists after first board exits" "$([ -n "$pid_after_kill" ] && printf yes || printf no)" "yes"
check "pidfile still contains second board's pid" "$pid_after_kill" "$pid_b"

# Clean up second board
kill "$job_b" 2>/dev/null || true
wait "$job_b" 2>/dev/null || true

rm -f "$test_pidfile"
rm -rf "$(dirname "$p")"

printf '\nclaude-dash-toggle\n'

STUB_BIN=$HERE/stub

# tree_json STATE VISIBLE — a minimal get_tree reply. STATE "absent" yields a
# tree with no matching window at all.
tree_json() {
  if [[ $1 == absent ]]; then
    jq -n '{nodes:[{nodes:[],floating_nodes:[]}]}'
  else
    jq -n --arg s "$1" --argjson v "$2" \
      '{nodes:[{nodes:[{app_id:"claude-dash",scratchpad_state:$s,visible:$v}],
                floating_nodes:[]}]}'
  fi
}

# run_toggle STATE VISIBLE — run the toggle against a canned tree, print the log.
# Unless CLAUDE_DASH_NO_BOARD is set, a real throwaway process stands in for the
# board: it traps USR1/USR2, appends what it received to the log, and its pid
# goes in the pidfile. That exercises the signal path end to end, which stubbing
# the `kill` builtin cannot do.
run_toggle() {
  local d fake_pid; d=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-toggle.XXXXXX")
  tree_json "$1" "$2" >"$d/tree.json"
  : >"$d/log"
  if [[ -z ${CLAUDE_DASH_NO_BOARD:-} ]]; then
    STUB_LOG=$d/log "$STUB_BIN/fakeboard" & fake_pid=$!
    printf '%s' "$fake_pid" >"$d/board.pid"
  fi
  PATH="$STUB_BIN:$PATH" STUB_TREE=$d/tree.json STUB_LOG=$d/log \
    CLAUDE_DASH_PIDFILE=$d/board.pid \
    CLAUDE_DASH_BOARD=$STUB_BIN/foot timeout 5 "$BIN/claude-dash-toggle" \
    >/dev/null 2>&1
  local rc=$?
  sleep 0.2                      # let the trap in the fake board run
  [[ -n ${fake_pid:-} ]] && kill "$fake_pid" 2>/dev/null
  cat "$d/log"
  rm -rf "$d"
  return "$rc"
}

log=$(run_toggle fresh true)
check "parked window is shown" \
  "$(printf '%s' "$log" | grep -c 'scratchpad show')" "1"
check "parked window is not moved again" \
  "$(printf '%s' "$log" | grep -c 'move scratchpad')" "0"
check "showing a visible window signals the board to resume" \
  "$(printf '%s' "$log" | grep -c '^USR2$')" "1"

log=$(run_toggle fresh false)
check "hiding signals the board to idle" \
  "$(printf '%s' "$log" | grep -c '^USR1$')" "1"

log=$(run_toggle none true)
check "unparked window is moved to the scratchpad first" \
  "$(printf '%s' "$log" | grep -c 'move scratchpad')" "1"
check "move precedes show" \
  "$(printf '%s' "$log" | grep -n 'move scratchpad\|scratchpad show' | head -1 | grep -c move)" "1"

# No board running for this case, so no stand-in process and no pidfile.
log=$(CLAUDE_DASH_NO_BOARD=1 run_toggle absent false); TOGGLE_RC=$?
check "absent window launches the board" \
  "$(printf '%s' "$log" | grep -c '^foot ')" "1"
check "a window that never appears exits non-zero" \
  "$([[ $TOGGLE_RC -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# A live board with no window yet (the double-click window) must not launch a
# second one -- this is the race the launch lock exists to prevent.
log=$(run_toggle absent false)
check "a live board is never launched twice" \
  "$(printf '%s' "$log" | grep -c '^foot ')" "0"

summary

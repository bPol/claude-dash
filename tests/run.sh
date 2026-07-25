#!/usr/bin/env bash
# Run with: ./tests/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
BIN=$HERE/../bin
DEAD_PID=4194303   # above /proc/sys/kernel/pid_max default, can never be live

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

# jobs_map is built from every jobs/*/state.json in one pass; if a single
# unrelated job file is corrupt, a live blocked session's OWN job state must
# not be lost with it -- only the corrupt file itself should cost anything.
root=$(new_root)
mk_session "$root" "$$" bg "blocked one" idle 5000 j-live
mk_job "$root" j-live blocked "please answer"
mkdir -p "$root/jobs/j-corrupt"
printf '{"state":"blocked"' >"$root/jobs/j-corrupt/state.json"   # truncated/corrupt
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "a corrupt unrelated job file does not blind a live session's state" \
  "$(jq -r '.sessions[0].state' <<<"$out")" "blocked"
check "a corrupt unrelated job file does not blind a live session's needs" \
  "$(jq -r '.sessions[0].needs' <<<"$out")" "please answer"
check "the corrupt unrelated job file is counted as unreadable" \
  "$(jq -r '.unreadable' <<<"$out")" "1"
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

# job_row's name and needs are job-authored free text same as a session's,
# rendered into the same Pango-markup tooltip -- they must go through `clean`
# too, not just the session path's fields.
root=$(new_root)
mk_orphan_job "$root" j-orphan-markup blocked \
  "$(printf 'fix <b>bug</b>\033[31m')" "/home/u/x" \
  "$(printf 'ok <i>now</i>\aplease')"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "orphan job name is markup-escaped and stripped of control chars" \
  "$(jq -r '.sessions[0].name' <<<"$out")" "fix &lt;b&gt;bug&lt;/b&gt;[31m"
check "orphan job needs is markup-escaped and stripped of control chars" \
  "$(jq -r '.sessions[0].needs' <<<"$out")" "ok &lt;i&gt;now&lt;/i&gt;please"
rm -rf "$root"

# cwd is not agent-authored the way name/needs are, but it still comes off
# disk verbatim and reaches the same Pango tooltip and terminal frame, so it
# must be sanitised too -- on the job-derived path here, and the
# session-derived path below.
root=$(new_root)
mk_orphan_job "$root" j-orphan-cwd blocked "cwd test" \
  "$(printf '/home/u/<script>\033[31m')" "ok"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "orphan job cwd is markup-escaped and stripped of control chars" \
  "$(jq -r '.sessions[0].cwd' <<<"$out")" "/home/u/&lt;script&gt;[31m"
rm -rf "$root"

root=$(new_root)
cwd_json=$(printf '/home/u/<script>\033[31m' | jq -Rs .)
now=$(date +%s%3N)
printf '{"pid":%d,"sessionId":"s-%d","cwd":%s,"startedAt":%d,"procStart":"%s","version":"2.1.219","kind":"interactive","entrypoint":"cli","name":"cwd test","status":"idle","updatedAt":%d,"statusUpdatedAt":%d}\n' \
  "$$" "$$" "$cwd_json" "$now" "$(proc_start_of "$$")" "$now" "$now" >"$root/sessions/$$.json"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "session cwd is markup-escaped and stripped of control chars" \
  "$(jq -r '.sessions[0].cwd' <<<"$out")" "/home/u/&lt;script&gt;[31m"
rm -rf "$root"

# A state.json that parses but has no usable `.state` (an empty object, or a
# file caught mid-write) must not read as busy forever -- that phantom row is
# the whole reason a corrupt/incomplete job file is dangerous here.
root=$(new_root)
mkdir -p "$root/jobs/j-empty"
printf '{}' >"$root/jobs/j-empty/state.json"
out=$(CLAUDE_DASH_ROOT=$root "$BIN/claude-sessions")
check "a job with no usable state is not working" \
  "$(jq -r '.sessions[0].working' <<<"$out")" "false"
check "a job with no usable state has null state" \
  "$(jq -r '.sessions[0].state' <<<"$out")" "null"
rm -rf "$root"

root=$(new_root)
# shellcheck disable=SC1010 # "done" here is the job state arg, not the loop keyword
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

printf '\nclaude-dash-fetch\n'

SSH_STUB=$HERE/stub/ssh

root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "ok-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "cache file is created for a reachable host" \
  "$([[ -f $cache/ok-host.json ]] && echo yes || echo no)" "yes"
check "cache file reports ok:true" \
  "$(jq -r '.ok' "$cache/ok-host.json")" "true"
check "cache file carries the remote payload's session" \
  "$(jq -r '.payload.sessions[0].name' "$cache/ok-host.json")" "remote task"
check "cache file has no error on success" \
  "$(jq -r '.error' "$cache/ok-host.json")" "null"
check "cache file records a numeric fetched_at" \
  "$(jq -r '.fetched_at | type' "$cache/ok-host.json")" "number"
check "no stray temp files are left behind (atomic write)" \
  "$(find "$cache" -maxdepth 1 -name '.ok-host.*' ! -name '.ok-host.lock' | wc -l | tr -d ' ')" "0"
rm -rf "$root"

root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "unreachable-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "unreachable host is recorded as not ok" \
  "$(jq -r '.ok' "$cache/unreachable-host.json")" "false"
check "unreachable host gets a null payload with no prior cache" \
  "$(jq -r '.payload' "$cache/unreachable-host.json")" "null"
check "unreachable host's error mentions the DNS failure" \
  "$(jq -r '.error | contains("unreachable")' "$cache/unreachable-host.json")" "true"
rm -rf "$root"

root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "authfail-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "auth failure is distinguished from a generic unreachable error" \
  "$(jq -r '.error' "$cache/authfail-host.json")" "auth failed"
rm -rf "$root"

root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "missingcmd-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "a remote with no claude-sessions installed is distinguished" \
  "$(jq -r '.error' "$cache/missingcmd-host.json")" "remote command missing"
rm -rf "$root"

# A host that answered with garbage (not JSON at all) must not be treated as
# a successful fetch just because ssh itself exited 0.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "badjson-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "a non-JSON response from ssh is not treated as ok" \
  "$(jq -r '.ok' "$cache/badjson-host.json")" "false"
rm -rf "$root"

# A host that was reachable once and then goes down must keep the LAST
# successful payload in the cache file, not lose it.
root=$(new_root)
cache=$root/cache
mkdir -p "$cache"
jq -n '{host:"ok-host",fetched_at:1,ok:true,error:null,
        payload:{host:"ok-host",generated_at:1,degraded:false,unreadable:0,
                 sessions:[{"kind":"interactive","pid":9,"name":"last known","cwd":"/x",
                            "status":"idle","working":false,"state":null,"needs":null,
                            "idle_ms":1,"job_id":null,"finished":false}]}}' \
  >"$cache/ok-host.json"
hosts=$root/hosts
mk_hosts_file "$hosts" "unreachable-host"
# Rewrite the fixture to look like ok-host failing this round: reuse the same
# cache file path by pointing the hosts file at unreachable-host but priming
# the cache under that same name first.
mv "$cache/ok-host.json" "$cache/unreachable-host.json"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "a failed refetch is marked not ok" \
  "$(jq -r '.ok' "$cache/unreachable-host.json")" "false"
check "a failed refetch preserves the previous payload" \
  "$(jq -r '.payload.sessions[0].name' "$cache/unreachable-host.json")" "last known"
check "a failed refetch still records the new error" \
  "$(jq -r '.error | contains("unreachable")' "$cache/unreachable-host.json")" "true"
rm -rf "$root"

# --host refreshes exactly the named host, leaving the hosts file (and any
# other cached host) untouched -- how the other scenarios above are tested
# in isolation, and how a person debugs one host by hand.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "ok-host" "blocked-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch" --host blocked-host
check "--host fetches only the named host" \
  "$([[ -f $cache/blocked-host.json ]] && echo yes || echo no)" "yes"
check "--host does not fetch the other configured hosts" \
  "$([[ -f $cache/ok-host.json ]] && echo yes || echo no)" "no"
check "--host works even without a hosts file at all" \
  "$(CLAUDE_DASH_HOSTS=$root/no-such-file CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
     "$BIN/claude-dash-fetch" --host ok-host; jq -r '.ok' "$cache/ok-host.json")" "true"
rm -rf "$root"

# user@host normalises to the bare host for both the cache filename and the
# host field inside it -- the login user must never leak into a label.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "deploy@ok-host"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "user@host cache file is named by host only" \
  "$([[ -f $cache/ok-host.json ]] && echo yes || echo no)" "yes"
check "user@host's login user is not in the recorded host field" \
  "$(jq -r '.host' "$cache/ok-host.json")" "ok-host"
rm -rf "$root"

# Comments and blank lines in the hosts file are ignored, and a genuinely
# empty/absent hosts file fetches nothing (no error, no cache files).
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "# a comment" "" "   " "ok-host  " "# trailing comment"
CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "comments and blank lines are ignored, trailing whitespace trimmed" \
  "$(find "$cache" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" "1"
rm -rf "$root"

root=$(new_root)
cache=$root/cache
CLAUDE_DASH_HOSTS=$root/no-such-hosts-file CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch"
check "no hosts file at all fetches nothing and does not error" "$?" "0"
rm -rf "$root"

# Two hosts, one slow: the fast host's cache file must land well before the
# slow one finishes, proving the fetches ran in parallel rather than serially.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "ok-host" "slow-host"
t0=$(date +%s%N)
STUB_SSH_SLEEP=2 CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_SSH=$SSH_STUB \
  "$BIN/claude-dash-fetch" &
fetch_pid=$!
# Poll for the fast host's file to appear while the slow one is still running.
fast_seen_before_slow_done=no
for _ in $(seq 40); do
  if [[ -f $cache/ok-host.json ]]; then
    fast_seen_before_slow_done=yes
    break
  fi
  sleep 0.05
done
wait "$fetch_pid"
t1=$(date +%s%N)
elapsed_ms=$(((t1 - t0) / 1000000))
check "the fast host's cache appears before the slow host finishes" \
  "$fast_seen_before_slow_done" "yes"
check "one slow host does not double the total runtime (parallel, not serial)" \
  "$([[ $elapsed_ms -lt 3500 ]] && echo yes || echo no)" "yes"
rm -rf "$root"

# Two concurrent fetch runs for the same host: the per-host lock must let
# only one of them actually call ssh, so the loser leaves the winner's write
# alone instead of racing it.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "counted-host"
ssh_log=$root/ssh-log
: >"$ssh_log"
STUB_SSH_SLEEP=1 STUB_SSH_LOG=$ssh_log CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache \
  CLAUDE_DASH_SSH=$SSH_STUB "$BIN/claude-dash-fetch" &
p1=$!
sleep 0.1   # let the first run grab the lock before the second starts
STUB_SSH_SLEEP=1 STUB_SSH_LOG=$ssh_log CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_CACHE=$cache \
  CLAUDE_DASH_SSH=$SSH_STUB "$BIN/claude-dash-fetch" &
p2=$!
wait "$p1" "$p2"
check "a concurrent fetch for the same host is skipped, not double-run" \
  "$(wc -l <"$ssh_log" | tr -d ' ')" "1"
rm -rf "$root"

printf '\nclaude-sessions-all\n'

# No cache, no hosts file: output must be plain claude-sessions plus a host
# field on every session and a one-entry hosts array -- the fallback that
# keeps a single-machine setup working unchanged.
root=$(new_root)
cache=$root/cache
hosts=$root/no-such-hosts-file
lp=$(producer_stub '[{"kind":"interactive","pid":1,"name":"local task","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
out=$(CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$hosts \
      "$BIN/claude-sessions-all")
check "no cache/no hosts: session count matches the local producer" \
  "$(jq -r '.sessions | length' <<<"$out")" "1"
check "no cache/no hosts: session gets the local host field" \
  "$(jq -r '.sessions[0].host' <<<"$out")" "testbox"
check "no cache/no hosts: hosts array has exactly one entry" \
  "$(jq -r '.hosts | length' <<<"$out")" "1"
check "no cache/no hosts: the one hosts entry is local" \
  "$(jq -r '.hosts[0].kind' <<<"$out")" "local"
check "no cache/no hosts: the one hosts entry is fresh" \
  "$(jq -r '.hosts[0].status' <<<"$out")" "fresh"
check "no cache/no hosts: top-level host matches the local producer's" \
  "$(jq -r '.host' <<<"$out")" "testbox"
rm -rf "$(dirname "$lp")" "$root"

# A fresh remote cache merges in and is labelled with its host.
root=$(new_root)
cache=$root/cache
lp=$(producer_stub '[{"kind":"interactive","pid":1,"name":"local task","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
mk_cache_file "$cache" "remote1" true "" 0 \
  '[{"kind":"interactive","pid":9,"name":"remote task","cwd":"/y","status":"idle","working":false,"state":null,"needs":null,"idle_ms":500,"job_id":null,"finished":false}]'
out=$(CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$root/no-hosts \
      "$BIN/claude-sessions-all")
check "fresh remote: total session count is local + remote" \
  "$(jq -r '.sessions | length' <<<"$out")" "2"
check "fresh remote: the remote row is labelled with its host" \
  "$(jq -r '[.sessions[] | select(.name == "remote task")][0].host' <<<"$out")" "remote1"
check "fresh remote: hosts array includes the remote" \
  "$(jq -r '.hosts | length' <<<"$out")" "2"
check "fresh remote: remote host status is fresh" \
  "$(jq -r '[.hosts[] | select(.host == "remote1")][0].status' <<<"$out")" "fresh"
rm -rf "$(dirname "$lp")" "$root"

# A stale remote (older than CLAUDE_DASH_STALE_AFTER) is marked stale but its
# rows still show -- staleness must never hide data.
root=$(new_root)
cache=$root/cache
lp=$(producer_stub '[]')
mk_cache_file "$cache" "remote2" true "" 100 \
  '[{"kind":"bg","pid":null,"name":"stale remote row","cwd":"/z","status":"idle","working":false,"state":null,"needs":null,"idle_ms":100000,"job_id":"j1","finished":false}]'
out=$(CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$root/no-hosts \
      CLAUDE_DASH_STALE_AFTER=45 "$BIN/claude-sessions-all")
check "stale remote: host status is stale" \
  "$(jq -r '[.hosts[] | select(.host == "remote2")][0].status' <<<"$out")" "stale"
check "stale remote: its row still shows" \
  "$(jq -r '[.sessions[] | select(.name == "stale remote row")] | length' <<<"$out")" "1"
rm -rf "$(dirname "$lp")" "$root"

# An unreachable remote (last fetch failed) shows the error and keeps
# last-known rows instead of losing them.
root=$(new_root)
cache=$root/cache
lp=$(producer_stub '[]')
mk_cache_file "$cache" "remote3" false "unreachable" 5 \
  '[{"kind":"interactive","pid":9,"name":"last known remote row","cwd":"/y","status":"idle","working":false,"state":null,"needs":null,"idle_ms":500,"job_id":null,"finished":false}]'
out=$(CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$root/no-hosts \
      "$BIN/claude-sessions-all")
check "unreachable remote: host status is unreachable" \
  "$(jq -r '[.hosts[] | select(.host == "remote3")][0].status' <<<"$out")" "unreachable"
check "unreachable remote: error is surfaced" \
  "$(jq -r '[.hosts[] | select(.host == "remote3")][0].error' <<<"$out")" "unreachable"
check "unreachable remote: last-known row still shows" \
  "$(jq -r '[.sessions[] | select(.name == "last known remote row")] | length' <<<"$out")" "1"
rm -rf "$(dirname "$lp")" "$root"

# A cache file with genuinely corrupt JSON must not break the merge or lose
# local rows -- only that one remote's contribution is lost.
root=$(new_root)
cache=$root/cache
mkdir -p "$cache"
printf 'not json at all {{{' >"$cache/remote4.json"
lp=$(producer_stub '[{"kind":"interactive","pid":1,"name":"local survives","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
out=$(CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$root/no-hosts \
      "$BIN/claude-sessions-all")
check "corrupt cache file: exit code is still 0" "$?" "0"
check "corrupt cache file: local row survives" \
  "$(jq -r '[.sessions[] | select(.name == "local survives")] | length' <<<"$out")" "1"
check "corrupt cache file: output is still valid JSON" \
  "$(jq -e . >/dev/null 2>&1 <<<"$out" && echo yes || echo no)" "yes"
rm -rf "$(dirname "$lp")" "$root"

# Ordering: every local row precedes every remote row.
root=$(new_root)
cache=$root/cache
lp=$(producer_stub '[
  {"kind":"interactive","pid":1,"name":"local a","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false},
  {"kind":"interactive","pid":2,"name":"local b","cwd":"/x","status":"idle","working":false,"state":null,"needs":null,"idle_ms":2000,"job_id":null,"finished":false}]')
mk_cache_file "$cache" "remote5" true "" 0 \
  '[{"kind":"interactive","pid":9,"name":"remote a","cwd":"/y","status":"idle","working":false,"state":null,"needs":null,"idle_ms":500,"job_id":null,"finished":false}]'
out=$(CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$root/no-hosts \
      "$BIN/claude-sessions-all")
check "ordering: local rows precede remote rows" \
  "$(jq -r '[.sessions[].host] | . as $h | ($h | index("testbox")) < ($h | index("remote5"))' <<<"$out")" \
  "true"
check "ordering: first two rows are local" \
  "$(jq -r '.sessions[0:2] | map(.host == "testbox") | all' <<<"$out")" "true"
check "ordering: last row is remote" \
  "$(jq -r '.sessions[-1].host' <<<"$out")" "remote5"
rm -rf "$(dirname "$lp")" "$root"

# claude-sessions-all must never block on the network: when a fetch is due
# (no cache, hosts file present) it spawns claude-dash-fetch fully detached
# and returns immediately with whatever is on disk right now, even though
# the ssh it kicks off will sleep for 10s.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "slow-host"
lp=$(producer_stub '[]')
t0=$(date +%s%N)
out=$(STUB_SSH_SLEEP=10 CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache \
      CLAUDE_DASH_HOSTS=$hosts CLAUDE_DASH_SSH="$SSH_STUB" \
      CLAUDE_DASH_FETCH="$BIN/claude-dash-fetch" "$BIN/claude-sessions-all")
t1=$(date +%s%N)
elapsed_ms=$(((t1 - t0) / 1000000))
printf '  .. claude-sessions-all with a 10s-sleeping remote returned in %dms\n' "$elapsed_ms"
check "does not block: returns well under the remote's 10s sleep" \
  "$([[ $elapsed_ms -lt 2000 ]] && echo fast || echo slow)" "fast"
check "does not block: still returns valid JSON while the fetch runs in the background" \
  "$(jq -e . >/dev/null 2>&1 <<<"$out" && echo yes || echo no)" "yes"
rm -rf "$(dirname "$lp")" "$root"

# Measure the plain-old-local-only baseline for comparison in the report.
root=$(new_root)
lp=$(producer_stub '[]')
t0=$(date +%s%N)
"$BIN/claude-sessions" >/dev/null 2>&1
t1=$(date +%s%N)
baseline_ms=$(((t1 - t0) / 1000000))
printf '  .. plain claude-sessions (empty registry) baseline: %dms\n' "$baseline_ms"
rm -rf "$(dirname "$lp")" "$root"

# The spawn is rate-limited: a fetch is triggered at most once per
# CLAUDE_DASH_FETCH_EVERY window, so a 2s poll cannot spawn one every tick.
root=$(new_root)
cache=$root/cache
hosts=$root/hosts
mk_hosts_file "$hosts" "ok-host"
lp=$(producer_stub '[]')
fetch_log=$root/fetch-log
fetch_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-fetchstub.XXXXXX")
cat >"$fetch_stub_dir/fetch" <<STUB
#!/usr/bin/env bash
printf 'called\n' >>"$fetch_log"
STUB
chmod +x "$fetch_stub_dir/fetch"
CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$hosts \
  CLAUDE_DASH_FETCH="$fetch_stub_dir/fetch" CLAUDE_DASH_FETCH_EVERY=20 \
  "$BIN/claude-sessions-all" >/dev/null
sleep 0.2
CLAUDE_DASH_LOCAL_PRODUCER=$lp CLAUDE_DASH_CACHE=$cache CLAUDE_DASH_HOSTS=$hosts \
  CLAUDE_DASH_FETCH="$fetch_stub_dir/fetch" CLAUDE_DASH_FETCH_EVERY=20 \
  "$BIN/claude-sessions-all" >/dev/null
sleep 0.2
check "a second call inside the rate-limit window does not spawn another fetch" \
  "$(wc -l <"$fetch_log" 2>/dev/null | tr -d ' ')" "1"
rm -rf "$(dirname "$lp")" "$fetch_stub_dir" "$root"

printf '\nclaude-dash-badge\n'

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

# The registry exists but every file is corrupt and the CLI is unreachable:
# the producer legitimately emits degraded:false, unreadable:N, sessions:[].
# That must not read as "nothing running" (0▸0▸0, quiet) -- it's the exact
# confusion this tool exists to remove.
d=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-prod.XXXXXX")
{ printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n'
  jq -n '{host:"testbox",generated_at:0,degraded:false,unreadable:3,sessions:[]}'
  printf 'JSON\n'; } >"$d/producer"
chmod +x "$d/producer"
out=$(CLAUDE_DASH_PRODUCER=$d/producer "$BIN/claude-dash-badge")
check "zero sessions with unreadable files renders as unknown, not quiet" \
  "$(jq -r '.text' <<<"$out")" "?"
check "zero sessions with unreadable files is the error class" \
  "$(jq -r '.class' <<<"$out")" "error"
check "unreadable count is surfaced in the tooltip" \
  "$(jq -r '.tooltip | contains("3 unreadable")' <<<"$out")" "true"
rm -rf "$d"

# unreadable > 0 alongside real sessions must still surface in the tooltip
# (only the zero-sessions case flips text/class to the unknown glyph).
d=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-prod.XXXXXX")
{ printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n'
  jq -n '{host:"testbox",generated_at:0,degraded:false,unreadable:1,
          sessions:[{"kind":"interactive","pid":1,"name":"n","cwd":"/x","status":"busy",
                     "working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]}'
  printf 'JSON\n'; } >"$d/producer"
chmod +x "$d/producer"
out=$(CLAUDE_DASH_PRODUCER=$d/producer "$BIN/claude-dash-badge")
check "unreadable alongside real sessions keeps the normal glyph" \
  "$(jq -r '.text' <<<"$out")" "1▸0▸0"
check "unreadable alongside real sessions is still surfaced in the tooltip" \
  "$(jq -r '.tooltip | contains("1 unreadable")' <<<"$out")" "true"
rm -rf "$d"

# A row that is both working and blocked (reachable now that job-derived rows
# exist) must be counted once, as blocked -- not once in each bucket, which
# would break busy+blocked+idle == unfinished sessions.
p=$(producer_stub '[
  {"kind":"bg","pid":1,"name":"working and blocked","cwd":"/x","status":"busy","working":true,"state":"blocked","needs":"n","idle_ms":1000,"job_id":"j1","finished":false},
  {"kind":"interactive","pid":2,"name":"plain busy","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false},
  {"kind":"interactive","pid":3,"name":"plain idle","cwd":"/x","status":"idle","working":false,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
out=$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge")
check "a row that is both working and blocked counts once, as blocked" \
  "$(jq -r '.text' <<<"$out")" "1▸1▸1"
rm -rf "$(dirname "$p")"

printf '\nclaude-dash-badge: multi-host (claude-sessions-all shaped output)\n'

multi_producer_stub() {   # multi_producer_stub HOSTS_JSON SESSIONS_JSON -> path
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-multiprod.XXXXXX")
  { printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n'
    jq -n --argjson h "$1" --argjson s "$2" \
      '{host:"local-box",generated_at:0,degraded:false,unreadable:0,hosts:$h,sessions:$s}'
    printf 'JSON\n'
  } >"$d/producer"
  chmod +x "$d/producer"
  printf '%s' "$d/producer"
}

# A blocked agent on a REMOTE host must turn the badge amber, exactly like a
# local one -- counts are over every host in the merged producer's output.
p=$(multi_producer_stub \
  '[{"host":"local-box","kind":"local","fetched_at":0,"age_ms":0,"status":"fresh","error":null},
    {"host":"worker-pc","kind":"remote","fetched_at":0,"age_ms":1000,"status":"fresh","error":null}]' \
  '[{"kind":"interactive","pid":1,"name":"local idle","cwd":"/x","status":"idle","working":false,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false,"host":"local-box"},
    {"kind":"bg","pid":null,"name":"remote blocked agent","cwd":"/y","status":"idle","working":false,"state":"blocked","needs":"answer me","idle_ms":2000,"job_id":"j1","finished":false,"host":"worker-pc"}]')
out=$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge")
check "a remote blocked agent sets the alert (amber) class" \
  "$(jq -r '.class' <<<"$out")" "alert"
check "a remote blocked agent is counted in the badge text" \
  "$(jq -r '.text' <<<"$out")" "0▸1▸1"
check "tooltip groups the remote row under its own host heading" \
  "$(jq -r '.tooltip | contains("worker-pc")' <<<"$out")" "true"
check "tooltip mentions the remote blocked agent" \
  "$(jq -r '.tooltip | contains("remote blocked agent")' <<<"$out")" "true"
rm -rf "$(dirname "$p")"

# A stale remote host heading shows a relative age; an unreachable one shows
# "unreachable" with its error, and its rows (last-known) still appear.
p=$(multi_producer_stub \
  '[{"host":"local-box","kind":"local","fetched_at":0,"age_ms":0,"status":"fresh","error":null},
    {"host":"stale-pc","kind":"remote","fetched_at":0,"age_ms":180000,"status":"stale","error":null},
    {"host":"down-pc","kind":"remote","fetched_at":0,"age_ms":600000,"status":"unreachable","error":"unreachable (dns)"}]' \
  '[{"kind":"interactive","pid":1,"name":"last known on down-pc","cwd":"/y","status":"idle","working":false,"state":null,"needs":null,"idle_ms":600000,"job_id":null,"finished":false,"host":"down-pc"}]')
out=$(CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash-badge")
check "a stale remote's heading shows a relative age" \
  "$(jq -r '.tooltip | contains("stale-pc") and contains("3m ago")' <<<"$out")" "true"
check "an unreachable remote's heading shows the word unreachable" \
  "$(jq -r '.tooltip | contains("down-pc") and contains("unreachable")' <<<"$out")" "true"
check "an unreachable remote's heading shows its error" \
  "$(jq -r '.tooltip | contains("unreachable (dns)")' <<<"$out")" "true"
check "an unreachable remote still shows its last-known row" \
  "$(jq -r '.tooltip | contains("last known on down-pc")' <<<"$out")" "true"
rm -rf "$(dirname "$p")"

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

# A name and a needs-text too long to fit their column must be cut with a
# trailing ellipsis, not silently chopped -- and the terminal-width guarantee
# must hold at every width, narrow ones included, where the mid-column
# arithmetic ($w - 46) can go negative.
p=$(producer_stub '[
  {"kind":"interactive","pid":1,"name":"a very long session name that will definitely need truncating","cwd":"/home/u/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":120000,"job_id":null,"finished":false},
  {"kind":"bg","pid":3,"name":"typo clarification","cwd":"/home/u/x","status":"idle","working":false,"state":"blocked","needs":"did you mean exit or edit, or something else entirely that runs well past any column width","idle_ms":360000,"job_id":"j","finished":false}]')
for w in 40 60 100 200; do
  frame=$(COLUMNS=$w CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)
  check "no frame line exceeds $w columns" \
    "$(awk -v w="$w" 'length > w' <<<"$frame" | wc -l)" "0"
done
frame=$(COLUMNS=60 CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)
check "a truncated name ends in an ellipsis" \
  "$(grep -c '…' <<<"$frame")" "2"
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

# Same mutual-exclusion requirement as the badge: a row both working and
# blocked must count once (as blocked), so busy+blocked+idle == live rows.
p=$(producer_stub '[
  {"kind":"bg","pid":1,"name":"working and blocked","cwd":"/x","status":"busy","working":true,"state":"blocked","needs":"n","idle_ms":1000,"job_id":"j1","finished":false},
  {"kind":"interactive","pid":2,"name":"plain busy","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false},
  {"kind":"interactive","pid":3,"name":"plain idle","cwd":"/x","status":"idle","working":false,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false}]')
frame=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)
check "board's busy/blocked/idle counts sum to the live session count" \
  "$(grep -oE '[0-9]+ busy · [0-9]+ blocked · [0-9]+ idle' <<<"$frame" \
     | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')" "3"
rm -rf "$(dirname "$p")"

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

printf '\nclaude-dash board: multi-host (claude-sessions-all shaped output)\n'

p=$(multi_producer_stub \
  '[{"host":"local-box","kind":"local","fetched_at":0,"age_ms":0,"status":"fresh","error":null},
    {"host":"worker-pc","kind":"remote","fetched_at":0,"age_ms":1000,"status":"fresh","error":null},
    {"host":"stale-pc","kind":"remote","fetched_at":0,"age_ms":180000,"status":"stale","error":null},
    {"host":"down-pc","kind":"remote","fetched_at":0,"age_ms":600000,"status":"unreachable","error":"unreachable (dns)"}]' \
  '[{"kind":"interactive","pid":1,"name":"local task","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false,"host":"local-box"},
    {"kind":"bg","pid":null,"name":"remote blocked agent","cwd":"/y","status":"idle","working":false,"state":"blocked","needs":"answer me","idle_ms":2000,"job_id":"j1","finished":false,"host":"worker-pc"},
    {"kind":"interactive","pid":null,"name":"stale remote row","cwd":"/z","status":"idle","working":false,"state":null,"needs":null,"idle_ms":180000,"job_id":null,"finished":false,"host":"stale-pc"},
    {"kind":"interactive","pid":null,"name":"last known on down-pc","cwd":"/w","status":"idle","working":false,"state":null,"needs":null,"idle_ms":600000,"job_id":null,"finished":false,"host":"down-pc"}]')
frame=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)
check "top header still names the local host" \
  "$(grep -c 'claude sessions · local-box' <<<"$frame")" "1"
check "local block has no host heading of its own" \
  "$(grep -c '^ local-box' <<<"$frame")" "0"
check "a fresh remote host gets its own block heading" \
  "$(grep -c '^ worker-pc' <<<"$frame")" "1"
check "the remote block's row is shown" \
  "$(grep -c 'remote blocked agent' <<<"$frame")" "1"
check "a stale remote host's heading shows a relative age" \
  "$(grep -c '^ stale-pc.*ago' <<<"$frame")" "1"
check "a stale remote's last-known row still shows" \
  "$(grep -c 'stale remote row' <<<"$frame")" "1"
check "an unreachable remote host's heading says unreachable with its error" \
  "$(grep -c '^ down-pc.*unreachable: unreachable (dns)' <<<"$frame")" "1"
check "an unreachable remote's last-known row still shows" \
  "$(grep -c 'last known on down-pc' <<<"$frame")" "1"
check "counts sum across every host, not just local" \
  "$(grep -oE '[0-9]+ busy · [0-9]+ blocked · [0-9]+ idle' <<<"$frame" \
     | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')" "4"
check "multi-host frame still respects the terminal width" \
  "$(awk 'length > 100' <<<"$frame" | wc -l)" "0"
rm -rf "$(dirname "$p")"

# A single-host claude-sessions-all-shaped producer (a real remote-configured
# setup where nothing else is remote yet) must render exactly like the plain
# local board: no remote block, just the local rows.
p=$(multi_producer_stub \
  '[{"host":"local-box","kind":"local","fetched_at":0,"age_ms":0,"status":"fresh","error":null}]' \
  '[{"kind":"interactive","pid":1,"name":"only local","cwd":"/x","status":"busy","working":true,"state":null,"needs":null,"idle_ms":1000,"job_id":null,"finished":false,"host":"local-box"}]')
frame=$(COLUMNS=100 CLAUDE_DASH_PRODUCER=$p "$BIN/claude-dash" --once)
check "a one-entry hosts array renders with no remote block at all" \
  "$(grep -cE '^ [a-z-]+-pc|^ local-box' <<<"$frame")" "0"
check "the sole local row still shows" \
  "$(grep -c 'only local' <<<"$frame")" "1"
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

printf '\ninstall.sh\n'

root=$(new_root)
bin_dir=$root/bindir
hosts_file=$root/config/claude-dash/hosts
CLAUDE_DASH_BIN_DIR=$bin_dir CLAUDE_DASH_HOSTS=$hosts_file PATH="$STUB_BIN:$PATH" \
  "$HERE/../install.sh" >/dev/null 2>"$root/install-stderr"
check "install.sh creates the hosts file when absent" \
  "$([[ -f $hosts_file ]] && echo yes || echo no)" "yes"
check "the created hosts file has no real host, only comments/blanks" \
  "$(grep -vc '^#\|^[[:space:]]*$' "$hosts_file")" "0"
check "install.sh symlinks claude-sessions-all" \
  "$([[ -L $bin_dir/claude-sessions-all ]] && echo yes || echo no)" "yes"
check "install.sh symlinks claude-dash-fetch" \
  "$([[ -L $bin_dir/claude-dash-fetch ]] && echo yes || echo no)" "yes"

# A re-run must not clobber a hosts file the user has since edited with a
# real host.
printf 'my-real-host\n' >>"$hosts_file"
CLAUDE_DASH_BIN_DIR=$bin_dir CLAUDE_DASH_HOSTS=$hosts_file PATH="$STUB_BIN:$PATH" \
  "$HERE/../install.sh" >/dev/null 2>"$root/install-stderr"
check "a re-run does not overwrite an existing hosts file" \
  "$(grep -c 'my-real-host' "$hosts_file")" "1"
rm -rf "$root"

summary

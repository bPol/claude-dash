#!/usr/bin/env bash
# Assertions and fixture builders for the claude-dash test suite.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

# proc_start_of PID — field 22 of /proc/PID/stat, non-zero exit if pid is gone.
proc_start_of() {
  local raw rest fields
  [[ -r /proc/$1/stat ]] || return 1
  raw=$(</proc/"$1"/stat) 2>/dev/null || return 1
  rest=${raw#*') '}
  read -ra fields <<<"$rest"
  printf '%s' "${fields[19]}"
}

# new_root — make an empty fixture tree, print its path.
new_root() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/claude-dash-test.XXXXXX")
  mkdir -p "$root/sessions" "$root/jobs"
  printf '%s' "$root"
}

# mk_session ROOT PID KIND NAME STATUS AGE_MS [JOB_ID] [PROC_START]
# PROC_START defaults to the pid's real start time, making the session live.
# Pass a bogus value to simulate pid reuse.
mk_session() {
  local root=$1 pid=$2 kind=$3 name=$4 status=$5 age=$6 job=${7:-} start=${8:-}
  local now updated job_field='' name_json
  [[ -n $start ]] || start=$(proc_start_of "$pid" || printf '0')
  now=$(date +%s%3N)
  updated=$((now - age))
  [[ -n $job ]] && job_field=",\"jobId\":\"$job\""
  # JSON-escape the name: it may carry control characters (a real JSON
  # writer would escape them too), and raw bytes here would make the
  # fixture invalid JSON.
  name_json=$(printf '%s' "$name" | jq -Rs .)
  printf '%s\n' "{\"pid\":$pid,\"sessionId\":\"s-$pid\",\"cwd\":\"/home/u/projects/demo\",\"startedAt\":$updated,\"procStart\":\"$start\",\"version\":\"2.1.219\",\"kind\":\"$kind\",\"entrypoint\":\"cli\",\"name\":$name_json,\"status\":\"$status\",\"updatedAt\":$updated,\"statusUpdatedAt\":$updated$job_field}" \
    >"$root/sessions/$pid.json"
}

# mk_job ROOT JOB_ID STATE [NEEDS]
mk_job() {
  local root=$1 id=$2 state=$3 needs=${4:-} needs_json=null
  mkdir -p "$root/jobs/$id"
  [[ -n $needs ]] && needs_json=$(printf '%s' "$needs" | jq -Rs .)
  printf '%s\n' "{\"state\":\"$state\",\"detail\":\"d\",\"tempo\":\"$state\",\"needs\":$needs_json}" \
    >"$root/jobs/$id/state.json"
}

# mk_orphan_job ROOT JOB_ID STATE NAME CWD [NEEDS] [UPDATED_AT_MS]
# A job directory with NO corresponding session file: the shape left behind
# when a background agent's process has already exited, including one that
# is blocked and waiting on the user. UPDATED_AT_MS, when given, is written
# as a numeric epoch-ms .updatedAt so idle_ms is deterministic instead of
# depending on the state.json file's mtime.
mk_orphan_job() {
  local root=$1 id=$2 state=$3 name=$4 cwd=$5 needs=${6:-} updated=${7:-}
  local needs_json=null name_json cwd_json updated_field=''
  mkdir -p "$root/jobs/$id"
  [[ -n $needs ]] && needs_json=$(printf '%s' "$needs" | jq -Rs .)
  name_json=$(printf '%s' "$name" | jq -Rs .)
  cwd_json=$(printf '%s' "$cwd" | jq -Rs .)
  [[ -n $updated ]] && updated_field=",\"updatedAt\":$updated"
  printf '%s\n' "{\"state\":\"$state\",\"detail\":\"d\",\"tempo\":\"$state\",\"needs\":$needs_json,\"name\":$name_json,\"cwd\":$cwd_json$updated_field}" \
    >"$root/jobs/$id/state.json"
}

# check DESCRIPTION ACTUAL EXPECTED
check() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"
  fi
}

summary() {
  printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ $TESTS_FAILED -eq 0 ]]
}

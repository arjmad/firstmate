#!/usr/bin/env bash
# Tests for bin/fm-claude-rc-archive.sh: `find` names only the torn-down task's
# own Claude Remote Control sessions (name AND launch directory must match),
# and `archive` sends Claude Code's own archive request with the token kept off
# the command line, treating every failure as a one-line warning and exit 0.
# A PATH-shimmed curl stands in for the API; nothing here reaches the network.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARCHIVE="$ROOT/bin/fm-claude-rc-archive.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-rc-archive-tests)

# A fresh case: a fake HOME with an empty ~/.claude, a pinned Claude root, a
# task worktree, and a fakebin whose curl logs its argv and stdin config and
# answers FAKE_CURL_CODE (default 200).
make_case() {
  local c=$TMP_ROOT/$1
  mkdir -p "$c/home/.claude/sessions" "$c/root/sessions" "$c/wt" "$c/other-wt" "$c/fakebin"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FAKE_token-123"}}\n' > "$c/root/.credentials.json"
  cat > "$c/fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
cat >> "$FAKE_CURL_LOG.stdin"
printf '%s' "${FAKE_CURL_CODE:-200}"
[ "${FAKE_CURL_CODE:-200}" != 000 ] || exit 28
SH
  chmod +x "$c/fakebin/curl"
  printf '%s\n' "$c"
}

session_record() {  # <root> <pid> <name> <cwd> [<bridge id>]
  local bridge=${5:-}
  if [ -n "$bridge" ]; then
    jq -n --argjson pid "$2" --arg n "$3" --arg c "$4" --arg b "$bridge" \
      '{pid: $pid, kind: "interactive", name: $n, cwd: $c, sessionId: "uuid-\($pid)", bridgeSessionId: $b}' \
      > "$1/sessions/$2.json"
  else
    jq -n --argjson pid "$2" --arg n "$3" --arg c "$4" \
      '{pid: $pid, kind: "interactive", name: $n, cwd: $c, sessionId: "uuid-\($pid)"}' > "$1/sessions/$2.json"
  fi
}

run_find() {  # <case> <task-id> <launch-dir> [<account>]
  local c=$1; shift
  HOME="$c/home" CLAUDE_CONFIG_DIR='' PATH="$c/fakebin:$PATH" "$ARCHIVE" find "$@"
}

run_archive() {  # <case> <task-id> <stdin-lines>
  local c=$1 id=$2 lines=$3
  printf '%s\n' "$lines" | HOME="$c/home" CLAUDE_CONFIG_DIR='' FAKE_CURL_LOG="$c/curl.log" \
    FM_CLAUDE_RC_API_BASE=https://api.example.invalid PATH="$c/fakebin:$PATH" "$ARCHIVE" archive "$id"
}

test_find_names_only_the_tasks_own_sessions() {
  local c out
  c=$(make_case find)
  session_record "$c/root" 101 task-a "$c/wt" session_01AAA
  session_record "$c/root" 102 "ship: task-a" "$c/wt" session_01BBB
  session_record "$c/root" 103 task-a "$c/other-wt" session_01CCC
  session_record "$c/root" 104 task-b "$c/wt" session_01DDD
  session_record "$c/root" 105 task-a "$c/wt"
  session_record "$c/root" 106 task-ab "$c/wt" session_01EEE
  printf '{"pid": 107, "name": "task-a", "cwd": ' > "$c/root/sessions/107.json"
  out=$(run_find "$c" task-a "$c/wt" "$c/root")
  [ "$out" = "$c/root"$'\t'session_01AAA$'\n'"$c/root"$'\t'session_01BBB ] \
    || fail "find: expected the bare and legacy-named records in the task worktree, got: $out"
  pass "find names the task's bare- and legacy-named sessions in its own launch directory only"
}

test_find_matches_a_symlinked_launch_dir_and_dedupes_roots() {
  local c out
  c=$(make_case symlink)
  ln -s "$c/wt" "$c/wt-link"
  session_record "$c/home/.claude" 201 task-a "$c/wt" session_01FFF
  out=$(run_find "$c" task-a "$c/wt-link" ordinary)
  [ "$out" = "$c/home/.claude"$'\t'session_01FFF ] \
    || fail "symlink: expected one line from the ordinary root, got: $out"
  out=$(run_find "$c" task-a "$c/wt")
  [ "$out" = "$c/home/.claude"$'\t'session_01FFF ] \
    || fail "symlink: an unpinned task must still find the record under \$HOME/.claude, got: $out"
  pass "find matches a symlinked launch directory and reads each root once"
}

test_find_with_nothing_recorded_prints_nothing() {
  local c out rc
  c=$(make_case empty)
  out=$(run_find "$c" task-a "$c/wt" "$c/root") && rc=0 || rc=$?
  expect_code 0 "$rc" "empty: find exits 0"
  [ -z "$out" ] || fail "empty: expected no output, got: $out"
  run_find "$c" task-a >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "usage: find without a launch dir"
  pass "find prints nothing when no session matches, and a missing argument is a usage error"
}

test_archive_sends_claudes_request_without_the_token_on_argv() {
  local c err rc
  c=$(make_case archive)
  err=$(run_archive "$c" task-a "$c/root"$'\t'session_01AAA 2>&1 >/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "archive: exit 0"
  [ "$err" = "archived Claude Remote Control session session_01AAA for task-a" ] \
    || fail "archive: unexpected report: $err"
  grep -q -- '-X POST .*https://api.example.invalid/v1/code/sessions/cse_01AAA/archive' "$c/curl.log" \
    || fail "archive: expected a POST to the cse_ archive path, got: $(cat "$c/curl.log")"
  grep -q 'anthropic-version: 2023-06-01' "$c/curl.log" || fail "archive: no anthropic-version header"
  ! grep -q 'FAKE_token' "$c/curl.log" || fail "archive: the token reached curl's argv"
  grep -qx 'header = "Authorization: Bearer sk-ant-oat01-FAKE_token-123"' "$c/curl.log.stdin" \
    || fail "archive: the token did not travel on curl's stdin config"
  pass "archive POSTs Claude Code's archive request with the token on stdin, not argv"
}

test_archive_treats_409_as_already_archived() {
  local c err
  c=$(make_case conflict)
  err=$(FAKE_CURL_CODE=409 run_archive "$c" task-a "$c/root"$'\t'cse_01AAA 2>&1 >/dev/null)
  [ "$err" = "archived Claude Remote Control session cse_01AAA for task-a" ] \
    || fail "409: expected success, got: $err"
  grep -q '/v1/code/sessions/cse_01AAA/archive' "$c/curl.log" || fail "409: cse_ id not kept as is"
  pass "archive accepts a cse_ id and treats 409 as already archived"
}

test_archive_failures_warn_once_and_exit_zero() {
  local c err rc
  c=$(make_case failures)
  err=$(FAKE_CURL_CODE=401 run_archive "$c" task-a "$c/root"$'\t'session_01AAA 2>&1 >/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "401: exit 0"
  [ "$err" = "warning: could not archive Claude Remote Control session session_01AAA for task-a: HTTP 401" ] \
    || fail "401: unexpected report: $err"
  err=$(FAKE_CURL_CODE=000 run_archive "$c" task-a "$c/root"$'\t'session_01AAA 2>&1 >/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "timeout: exit 0"
  [ "$err" = "warning: could not archive Claude Remote Control session session_01AAA for task-a: HTTP 000" ] \
    || fail "timeout: unexpected report: $err"
  rm "$c/root/.credentials.json"
  : > "$c/curl.log"
  err=$(run_archive "$c" task-a "$c/root"$'\t'session_01AAA 2>&1 >/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "no token: exit 0"
  [ "$err" = "warning: could not archive Claude Remote Control session session_01AAA for task-a: no stored OAuth token in $c/root" ] \
    || fail "no token: unexpected report: $err"
  [ ! -s "$c/curl.log" ] || fail "no token: curl ran anyway"
  err=$(run_archive "$c" task-a "$c/root"$'\t'session_../x 2>&1 >/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "bad id: exit 0"
  case "$err" in "warning: not archiving Claude Remote Control session 'session_../x' for task-a: not a session id") ;;
    *) fail "bad id: unexpected report: $err" ;; esac
  [ ! -s "$c/curl.log" ] || fail "bad id: curl ran anyway"
  pass "archive failures print one warning each and still exit 0"
}

test_archive_with_empty_input_does_nothing() {
  local c err rc
  c=$(make_case noinput)
  err=$(run_archive "$c" task-a '' 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "empty input: exit 0"
  [ -z "$err" ] || fail "empty input: unexpected output: $err"
  [ ! -e "$c/curl.log" ] || fail "empty input: curl ran"
  pass "archive with no found sessions sends nothing"
}

test_find_names_only_the_tasks_own_sessions
test_find_matches_a_symlinked_launch_dir_and_dedupes_roots
test_find_with_nothing_recorded_prints_nothing
test_archive_sends_claudes_request_without_the_token_on_argv
test_archive_treats_409_as_already_archived
test_archive_failures_warn_once_and_exit_zero
test_archive_with_empty_input_does_nothing

#!/usr/bin/env bash
# Behavior tests for the forced read of a spilled session-start digest:
# bin/fm-digest-read-check.sh (arm, check, record) and the Claude-only save and
# arm path in bin/fm-sessionstart-run.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-digest-read-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-digest-read-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
SID=0b1c2d3e-aaaa-bbbb-cccc-111122223333
OTHER_SID=99999999-aaaa-bbbb-cccc-111122223333

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

COPY="$STATE/.digest-read/$SID.txt"
PENDING="$STATE/.digest-read/$SID.pending"

# write_digest <file> <lines>: a digest whose first line is the head cue naming
# the copy, padded past the default 10,000-character spill threshold.
write_digest() {
  local file=$1 lines=$2
  mkdir -p "$(dirname "$file")"
  {
    printf 'READ CUE: if this output ends with "Output too large", read it. Saved at %s\n' "$COPY"
    awk -v n="$lines" 'BEGIN { for (i = 2; i <= n; i++) printf "digest line %04d padding padding padding padding\n", i }'
  } > "$file"
}

arm() {
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" arm "$SID" "$COPY" >/dev/null 2>&1
}

payload() {  # <session> <tool> [file_path] [offset] [limit]
  jq -cn --arg s "$1" --arg t "$2" --arg f "${3:-}" --arg o "${4:-}" --arg l "${5:-}" '
    { session_id: $s, hook_event_name: "PreToolUse", tool_name: $t,
      tool_input: ( {}
        + (if $f == "" then {} else { file_path: $f } end)
        + (if $o == "" then {} else { offset: ($o | tonumber) } end)
        + (if $l == "" then {} else { limit: ($l | tonumber) } end) ) }'
}

run_check() {  # <payload> [env...]
  local body=$1 rc=0
  shift
  : > "$OUT"; : > "$ERR"
  printf '%s' "$body" | env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" check --claude > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

run_record() {  # <payload>
  printf '%s' "$1" | env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" record >/dev/null 2>&1
}

expect_allow() {  # <label> <payload> [env...]
  local label=$1 body=$2 rc=0
  shift 2
  run_check "$body" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {  # <label> <payload>
  local label=$1 body=$2 rc=0
  run_check "$body" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg copy "$COPY" '.systemMessage | startswith("[digest-read]") and contains($copy)' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny message lost its code or the copy path: $(cat "$ERR")"
}

reset_arm() {
  rm -rf "$STATE/.digest-read"
  write_digest "$COPY" "${1:-1000}"
  arm
}

test_small_digest_never_arms() {
  rm -rf "$STATE/.digest-read"
  write_digest "$COPY" 20
  arm
  [ ! -e "$PENDING" ] || fail "a digest under the spill threshold armed the forced read"
  expect_allow "unarmed Bash" "$(payload "$SID" Bash)"
  pass "a digest small enough to show inline arms nothing"
}

test_spilled_digest_refuses_other_tools_until_read() {
  reset_arm 1000
  [ -f "$PENDING" ] || fail "a spilled-size digest did not arm"
  expect_deny "Bash while unread" "$(payload "$SID" Bash)"
  expect_deny "Edit while unread" "$(payload "$SID" Edit "$PRIMARY/AGENTS.md")"
  expect_deny "Read of another file" "$(payload "$SID" Read "$PRIMARY/AGENTS.md")"
  expect_deny "MCP tool while unread" "$(payload "$SID" mcp__x__y)"
  run_check "$(payload "$SID" Bash)" || true
  jq -e '.systemMessage | contains("1000 lines, still unread: 1-1000") and contains("blocked tool: Bash")' "$ERR" >/dev/null 2>&1 \
    || fail "deny message does not name the unread lines and blocked tool: $(cat "$ERR")"
  expect_allow "Read of the copy" "$(payload "$SID" Read "$COPY")"
  expect_allow "another session" "$(payload "$OTHER_SID" Bash)"
  pass "an armed session may only Read its digest, and other sessions are untouched"
}

test_chunked_reads_disarm_only_when_every_line_is_covered() {
  reset_arm 1000
  run_record "$(payload "$SID" Read "$COPY" 1 600)"
  [ -f "$PENDING" ] || fail "a partial read disarmed the forced read"
  run_check "$(payload "$SID" Bash)" || true
  jq -e '.systemMessage | contains("still unread: 601-1000")' "$ERR" >/dev/null 2>&1 \
    || fail "deny message does not narrow to the unread lines: $(cat "$ERR")"
  run_record "$(payload "$SID" Bash)"
  run_record "$(payload "$SID" Read "$PRIMARY/AGENTS.md")"
  [ -f "$PENDING" ] || fail "a read of another file disarmed the forced read"
  run_record "$(payload "$SID" Read "$COPY" 601 600)"
  [ ! -e "$PENDING" ] || fail "covering every line did not disarm"
  expect_allow "Bash after full read" "$(payload "$SID" Bash)"

  reset_arm 1000
  run_record "$(payload "$SID" Read "$COPY")"
  [ ! -e "$PENDING" ] || fail "one default 2000-line read of a 1000-line digest did not disarm"
  pass "chunked reads disarm only once every line is covered, and a default read covers 2000 lines"
}

test_spill_file_counts_only_when_it_is_this_digest() {
  local spill="$TMP_ROOT/claude/proj/$SID/tool-results/hook-1234-stdout.txt"
  local foreign="$TMP_ROOT/claude/proj/$SID/tool-results/hook-5678-stdout.txt"
  local other_session="$TMP_ROOT/claude/proj/$OTHER_SID/tool-results/hook-1234-stdout.txt"
  reset_arm 1000
  mkdir -p "$(dirname "$spill")" "$(dirname "$other_session")"
  cp "$COPY" "$spill"
  cp "$COPY" "$other_session"
  printf 'some other hook output\n' > "$foreign"
  expect_allow "Read of the spill" "$(payload "$SID" Read "$spill")"
  expect_deny "Read of another hook's spill" "$(payload "$SID" Read "$foreign")"
  expect_deny "Read of another session's spill" "$(payload "$SID" Read "$other_session")"
  run_record "$(payload "$SID" Read "$foreign")"
  [ -f "$PENDING" ] || fail "reading another hook's spill disarmed the forced read"
  run_record "$(payload "$SID" Read "$spill" 1 500)"
  run_record "$(payload "$SID" Read "$COPY" 501 500)"
  [ ! -e "$PENDING" ] || fail "reads split across the spill and the copy did not disarm"
  pass "the saved hook output counts as the digest only when its head cue matches"
}

test_rearm_requires_a_fresh_read() {
  reset_arm 1000
  run_record "$(payload "$SID" Read "$COPY")"
  [ ! -e "$PENDING" ] || fail "setup: full read did not disarm"
  write_digest "$COPY" 1200
  arm
  expect_deny "Bash after a re-emit" "$(payload "$SID" Bash)"
  pass "a later digest for the same session (a compaction re-emit) must be read again"
}

test_fail_open_paths() {
  local rc=0 linked="$TMP_ROOT/linked-repo" wt="$TMP_ROOT/linked-wt"
  reset_arm 1000
  expect_allow "escape hatch" "$(payload "$SID" Bash)" FM_ALLOW_UNREAD_DIGEST=1
  expect_allow "empty payload" ""
  expect_allow "malformed payload" "not json"
  expect_allow "invalid session id" "$(payload "../x" Bash)"
  rm -f "$COPY"
  expect_allow "missing copy" "$(payload "$SID" Bash)"
  [ ! -e "$PENDING" ] || fail "a missing copy did not disarm"

  # A linked task worktree is never a primary home, even with an arm record.
  fm_git_worktree "$linked" "$wt" digest-read-test
  mkdir -p "$wt/bin" "$wt/state/.digest-read"
  printf '# fixture\n' > "$wt/AGENTS.md"
  write_digest "$wt/state/.digest-read/$SID.txt" 1000
  printf 'copy %s\n' "$wt/state/.digest-read/$SID.txt" > "$wt/state/.digest-read/$SID.pending"
  : > "$OUT"; : > "$ERR"
  payload "$SID" Bash | env FM_ROOT_OVERRIDE="$wt" FM_HOME="$wt" FM_STATE_OVERRIDE="$wt/state" \
    "$CHECK" check --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$ERR" ] || fail "a linked task worktree was not inert: rc=$rc $(cat "$ERR")"
  pass "escape hatch, bad transport, a missing copy, and a task worktree all fail open"
}

test_runner_saves_and_arms_only_for_claude() {
  local fixture="$TMP_ROOT/runner" out copy pending
  mkdir -p "$fixture/bin" "$fixture/state" "$fixture/data" "$fixture/config"
  git -C "$fixture" init -q
  : > "$fixture/AGENTS.md"
  cp "$ROOT/bin/fm-sessionstart-run.sh" "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-digest-read-check.sh" "$fixture/bin/"
  [ ! -f "$ROOT/bin/fm-operational-input.sh" ] || cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf 'READ CUE: copy=%s\n' "${FM_SESSION_START_DIGEST_COPY:-none}"
i=0
while [ "$i" -lt "${FAKE_DIGEST_LINES:-400}" ]; do
  printf 'fake digest line %04d padding padding padding padding\n' "$i"
  i=$((i + 1))
done
SH
  chmod +x "$fixture/bin/"*.sh
  copy="$fixture/state/.digest-read/$SID.txt"
  pending="$fixture/state/.digest-read/$SID.pending"

  out=$(printf '{"source":"startup","session_id":"%s"}' "$SID" |
    env -u CLAUDE_ENV_FILE FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_GATE_REFUSE_BYPASS=1 \
      bash "$fixture/bin/fm-sessionstart-run.sh" --claude 2>/dev/null)
  [ -f "$copy" ] || fail "the Claude runner did not save the digest"
  assert_equals "$(cat "$copy")" "$out" "the printed digest differs from its saved copy"
  assert_contains "$(printf '%s' "$out" | head -n 1)" "copy=$copy" "the digest cue does not name its saved copy"
  [ -f "$pending" ] || fail "the Claude runner did not arm a spilled-size digest"

  rm -rf "$fixture/state/.digest-read"
  out=$(printf '{"source":"startup","session_id":"%s"}' "$SID" |
    env -u CLAUDE_ENV_FILE FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_GATE_REFUSE_BYPASS=1 \
      bash "$fixture/bin/fm-sessionstart-run.sh" 2>/dev/null)
  assert_contains "$out" "copy=none" "a non-Claude runner exported a digest copy"
  [ ! -e "$fixture/state/.digest-read" ] || fail "a non-Claude runner saved or armed the digest"

  out=$(printf '{"source":"startup","session_id":"%s"}' "$SID" |
    env -u CLAUDE_ENV_FILE FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_GATE_REFUSE_BYPASS=1 \
      FAKE_DIGEST_LINES=5 bash "$fixture/bin/fm-sessionstart-run.sh" --claude 2>/dev/null)
  [ -f "$copy" ] || fail "the Claude runner did not save a small digest"
  [ ! -e "$pending" ] || fail "the Claude runner armed a digest small enough to show inline"
  pass "the runner saves and arms the digest only for Claude, and only when it would spill"
}

test_small_digest_never_arms
test_spilled_digest_refuses_other_tools_until_read
test_chunked_reads_disarm_only_when_every_line_is_covered
test_spill_file_counts_only_when_it_is_this_digest
test_rearm_requires_a_fresh_read
test_fail_open_paths
test_runner_saves_and_arms_only_for_claude

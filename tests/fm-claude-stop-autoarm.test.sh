#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake Node harness whose script path is named "claude" and
# whose stable pid is written into the fixture home's state/.lock for ordinary
# owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

# Fixture-owned background processes (the takeover holder and outer lanes) are
# registered here by pid so a failed assertion never leaks a polling orphan.
FIXTURE_PIDS=()
fm_autoarm_teardown() {
  local pid
  for pid in "${FIXTURE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap fm_autoarm_teardown EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
cat > "$FAKEBIN/claude-harness.js" <<'JS'
#!/usr/bin/env node
const { spawn } = require("node:child_process");
const env = { ...process.env, FAKE_HARNESS_PID: String(process.pid) };
if (env.FAKE_NO_CLAUDE_PID === "1") delete env.CLAUDE_PID;
else if (!env.CLAUDE_PID) env.CLAUDE_PID = String(process.pid);
const child = spawn("/bin/bash", process.argv.slice(2), { env, stdio: "inherit" });
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => child.kill(signal));
}
child.on("exit", (code, signal) => {
  process.exit(signal ? 1 : (code ?? 1));
});
JS
cp "$FAKEBIN/claude-harness.js" "$FAKEBIN/codex-harness.js"
chmod +x "$FAKEBIN/claude-harness.js" "$FAKEBIN/codex-harness.js"
FAKE_CLAUDE="$FAKEBIN/claude-harness.js"
FAKE_CODEX="$FAKEBIN/codex-harness.js"
export FAKE_CLAUDE FAKE_CODEX

# The suite may itself run inside a real Claude session whose exported
# CLAUDE_PID is alive, Claude-shaped, and ancestral; the fake harness only
# injects its own pid when CLAUDE_PID is unset, so the ambient identity would
# hijack every fixture session's lock owner.
unset CLAUDE_PID

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh" "$dir/bin/fm-turnend-guard.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$CLAUDE_PID" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    actionable-then-slow)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
count=$(wc -l < "$FM_HOME/state/arm-ran" | tr -d ' ')
[ "$count" -eq 1 ] || sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture cycle %s\n' "$count"
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    meta-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.afk"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# --- registration contract ----------------------------------------------------

test_settings_registers_autoarm_with_multi_hour_timeout() {
  local settings
  settings="$ROOT/.claude/settings.json"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))]
      | length == 1
  ' "$settings" >/dev/null || fail "settings must register exactly one Stop auto-arm hook"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))][0]
      | .asyncRewake == true and .type == "command" and (.timeout | type == "number" and . >= 28800)
  ' "$settings" >/dev/null || fail "auto-arm must be asyncRewake with an explicit timeout of at least 28800s (the 600s default is forbidden)"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))][0].command
      | contains("&") | not
  ' "$settings" >/dev/null || fail "auto-arm registration must not use shell fire-and-forget"
  grep -q '"$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "auto-arm must foreground the arm wrapper inside the hook-owned process tree"
  grep -q 'asyncRewake' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "auto-arm header must document its asyncRewake registration contract"
  pass "settings.json registers the asyncRewake auto-arm with timeout >= 28800 and a foreground arm"
}

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_mid_session_takeover_claims_with_stable_claude_owner() {
  local dir holder outer outer_rc i guard_rc auto_rc owner expected_owner outcome
  dir=$(make_primary_dir "$TMP_ROOT/mid-session-takeover")
  mkdir -p "$dir/config"
  printf 'tmux\n' > "$dir/config/backend"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable

  # The old primary genuinely acquires the lock, then remains alive while the
  # replacement Claude session starts. This is the refused session-start edge
  # that precedes a mid-session takeover.
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    printf "%s\n" "$CLAUDE_PID" > "$FM_HOME/state/holder.pid"
    i=0
    while [ ! -e "$FM_HOME/state/holder.stop" ]; do
      i=$((i + 1)); [ "$i" -le 600 ] || exit 1
      sleep 0.05
    done
  ' &
  holder=$!
  FIXTURE_PIDS+=("$holder")
  i=0
  while [ ! -s "$dir/state/holder.pid" ]; do
    i=$((i + 1)); [ "$i" -le 200 ] || fail "timed out waiting for the old primary to acquire the home lock"
    sleep 0.05
  done

  cat > "$dir/bin/mid-session-takeover-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -u
lock_lane=
auto_pid=
cleanup() {
  local pid
  for pid in "$lock_lane" "$auto_pid"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT
# Claude exposes its stable session process to tool and hook children. Two
# transient Claude-shaped children below model the distinct execution lanes
# used by a mid-session lock command and the later Stop hook.
printf '%s\n' "$CLAUDE_PID" > "$FM_HOME/state/expected-owner"

pre_rc=0
printf '%s\n' '{"session_id":"takeover","stop_hook_active":false}' \
  | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1 || pre_rc=$?
printf '%s\n' "$pre_rc" > "$FM_HOME/state/pre.rc"

: > "$FM_HOME/state/holder.stop"
i=0
while "$FM_HOME/bin/fm-lock.sh" status | grep -q 'held by live'; do
  i=$((i + 1)); [ "$i" -le 200 ] || exit 65
  sleep 0.05
done

# Carry every suspected dead-session masking file across the takeover. Their
# age makes them reclaimable; none may permanently suppress the new claim.
old_pid=$(cat "$FM_HOME/state/holder.pid")
mkdir -p "$FM_HOME/state/.claude-autoarm.lock"
printf '9999999\n' > "$FM_HOME/state/.claude-autoarm.lock/pid"
printf 'epoch=7 owner_pid=%s outcome=arming updated_at=1\n' "$old_pid" > "$FM_HOME/state/.claude-autoarm-epoch"
printf 'session=dead-session\ncount=2\n' > "$FM_HOME/state/.turnend-claude-blocks"
touch -t 202001010000 "$FM_HOME/state/.claude-autoarm.lock" "$FM_HOME/state/.claude-autoarm-epoch"

# Keep the lock-command lane alive after acquisition. Before the fix its nearer
# Claude-shaped pid is written to .lock, so the sibling Stop lane mistakes the
# same session for a live competitor and never claims the auto-arm owner lock.
"$FAKE_CLAUDE" -c '
  "$FM_HOME/bin/fm-lock.sh" >/dev/null
  : > "$FM_HOME/state/takeover.locked"
  i=0
  while [ ! -e "$FM_HOME/state/takeover.release" ]; do
    i=$((i + 1)); [ "$i" -le 600 ] || exit 1
    sleep 0.05
  done
' &
lock_lane=$!
i=0
while [ ! -e "$FM_HOME/state/takeover.locked" ]; do
  i=$((i + 1)); [ "$i" -le 200 ] || exit 66
  sleep 0.05
done

printf '%s\n' '{"session_id":"takeover","stop_hook_active":false}' \
  | "$FAKE_CLAUDE" -c '
      rc=0
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh" || rc=$?
      :
      exit "$rc"
    ' >"$FM_HOME/state/auto.out" 2>"$FM_HOME/state/auto.err" &
auto_pid=$!

guard_rc=0
printf '%s\n' '{"session_id":"takeover","stop_hook_active":false}' \
  | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=5000 "$FM_HOME/bin/fm-turnend-guard.sh" --claude \
      >"$FM_HOME/state/guard.out" 2>"$FM_HOME/state/guard.err" || guard_rc=$?
printf '%s\n' "$guard_rc" > "$FM_HOME/state/guard.rc"

i=0
while kill -0 "$auto_pid" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -le 600 ] || exit 67
  sleep 0.05
done
auto_rc=0
wait "$auto_pid" || auto_rc=$?
printf '%s\n' "$auto_rc" > "$FM_HOME/state/auto.rc"
: > "$FM_HOME/state/takeover.release"
wait "$lock_lane"
SH
  chmod +x "$dir/bin/mid-session-takeover-fixture.sh"

  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    rc=0
    "$FM_HOME/bin/mid-session-takeover-fixture.sh" || rc=$?
    :
    exit "$rc"
  ' &
  outer=$!
  FIXTURE_PIDS+=("$outer")
  outer_rc=0
  wait "$outer" || outer_rc=$?
  wait "$holder" 2>/dev/null || true
  FIXTURE_PIDS=()

  expect_code 0 "$outer_rc" "takeover fixture must complete within its bounded deadlines"
  expect_code 0 "$(cat "$dir/state/pre.rc")" "replacement session must stay inert before the old live owner exits"
  guard_rc=$(cat "$dir/state/guard.rc")
  auto_rc=$(cat "$dir/state/auto.rc")
  owner=$(cat "$dir/state/.lock")
  expected_owner=$(cat "$dir/state/expected-owner")
  outcome=$(epoch_outcome "$dir")
  expect_code 0 "$guard_rc" "guard must allow once the takeover session's Stop hook owns recovery"
  expect_code 2 "$auto_rc" "takeover Stop hook must claim and translate the actionable watcher close"
  [ "$owner" = "$expected_owner" ] || fail "takeover lock must use Claude's stable session owner: expected $expected_owner, got $owner"
  [ "$outcome" = rewake ] || fail "takeover auto-arm must replace the carried epoch with outcome=rewake, got $outcome"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "successful takeover claim must reset the carried guard block budget"
  pass "auto-arm: mid-session takeover uses Claude's stable owner across lock-command and Stop-hook lanes"
}

test_restarted_session_hook_lane_claims_ancestral_lock_owner() {
  local dir rc guard_rc auto_rc owner expected_owner
  dir=$(make_primary_dir "$TMP_ROOT/restarted-session-hook-lane")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  printf '9999999\n' > "$dir/state/.lock"
  printf 'epoch=9 owner_pid=9999999 outcome=clean updated_at=1\n' > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"

  cat > "$dir/bin/restarted-session-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -u
auto_pid=
cleanup() {
  [ -n "$auto_pid" ] || return 0
  kill "$auto_pid" 2>/dev/null || true
  wait "$auto_pid" 2>/dev/null || true
}
trap cleanup EXIT

# Session start in the replacement primary re-acquires the home lock from its
# stable outer Claude process. Restarted Claude sessions dispatch Stop hooks
# through a nearer Claude daemon lane that does not expose CLAUDE_PID.
"$FM_HOME/bin/fm-lock.sh" >/dev/null
printf '%s\n' "$CLAUDE_PID" > "$FM_HOME/state/expected-owner"
payload='{"session_id":"restarted-session","stop_hook_active":false}'
printf '%s\n' "$payload" \
  | FAKE_NO_CLAUDE_PID=1 "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' \
      >"$FM_HOME/state/restart-auto.out" 2>"$FM_HOME/state/restart-auto.err" &
auto_pid=$!

guard_rc=0
printf '%s\n' "$payload" \
  | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=5000 "$FM_HOME/bin/fm-turnend-guard.sh" --claude \
      >"$FM_HOME/state/restart-guard.out" 2>"$FM_HOME/state/restart-guard.err" || guard_rc=$?
printf '%s\n' "$guard_rc" > "$FM_HOME/state/restart-guard.rc"

auto_rc=0
wait "$auto_pid" || auto_rc=$?
auto_pid=
printf '%s\n' "$auto_rc" > "$FM_HOME/state/restart-auto.rc"
SH
  chmod +x "$dir/bin/restarted-session-fixture.sh"

  rc=0
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/restarted-session-fixture.sh"' || rc=$?
  expect_code 0 "$rc" "restarted-session fixture must complete"
  guard_rc=$(cat "$dir/state/restart-guard.rc")
  auto_rc=$(cat "$dir/state/restart-auto.rc")
  owner=$(cat "$dir/state/.lock")
  expected_owner=$(cat "$dir/state/expected-owner")
  expect_code 0 "$guard_rc" "guard must allow the restarted session's daemon-lane auto-arm claim"
  expect_code 2 "$auto_rc" "restarted session's Stop hook must translate the actionable close"
  [ "$owner" = "$expected_owner" ] || fail "restarted session changed its reacquired lock owner: expected $expected_owner, got $owner"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "restarted session must replace the carried epoch with outcome=rewake"
  [ -e "$dir/state/arm-ran" ] || fail "restarted session's Stop hook never armed"
  pass "auto-arm: restarted-session daemon lane claims its live ancestral Claude lock owner"
}

test_inherited_claude_pid_does_not_override_nested_non_claude() {
  local dir owner expected
  dir=$(make_primary_dir "$TMP_ROOT/nested-non-claude")
  cat > "$dir/bin/nested-non-claude-fixture.sh" <<'SH'
#!/usr/bin/env bash
set -u
"$FAKE_CODEX" -c '
  printf "%s\n" "$FAKE_HARNESS_PID" > "$FM_HOME/state/expected-owner"
  "$FM_HOME/bin/fm-lock.sh" >/dev/null
'
SH
  chmod +x "$dir/bin/nested-non-claude-fixture.sh"
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    rc=0
    "$FM_HOME/bin/nested-non-claude-fixture.sh" || rc=$?
    :
    exit "$rc"
  '
  owner=$(cat "$dir/state/.lock")
  expected=$(cat "$dir/state/expected-owner")
  [ "$owner" = "$expected" ] || fail "an inherited CLAUDE_PID overrode the nested non-Claude harness: expected $expected, got $owner"
  pass "fm-lock: inherited CLAUDE_PID does not override a nested non-Claude harness"
}

test_nested_non_claude_lane_cannot_use_outer_claude_lock() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/nested-non-claude-autoarm")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable

  rc=0
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    "$FM_HOME/bin/fm-lock.sh" >/dev/null
    printf "%s\n" "{\"session_id\":\"nested-codex\"}" \
      | "$FAKE_CODEX" -c '\''"$FM_HOME/bin/fm-claude-stop-autoarm.sh"'\''
  ' || rc=$?
  expect_code 0 "$rc" "nested non-Claude lane must leave the outer Claude-owned home inert"
  [ ! -e "$dir/state/arm-ran" ] || fail "nested non-Claude lane used an ancestral outer Claude lock to arm"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "nested non-Claude lane wrote an auto-arm epoch"
  pass "auto-arm: nested non-Claude lane cannot use an outer Claude session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$CLAUDE_PID" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | CLAUDE_PID="$other" FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch while another session owned the lock"
  pass "auto-arm: inert without arm, rewake, or lock replacement when another live harness owns the home"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

test_ordinary_cycle_close_rearms_before_guard() {
  local dir dispatcher guard_rc auto_rc count
  dir=$(make_primary_dir "$TMP_ROOT/ordinary-cycle-close")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable-then-slow

  # Model Claude's registered Stop-hook dispatch order without a live session.
  # A synchronous exit 2 stops later hooks. An asyncRewake hook starts in the
  # background while dispatch continues, letting the guard observe its claim.
  dispatcher="$dir/bin/ordinary-close-dispatcher.sh"
  cat > "$dispatcher" <<'SH'
#!/usr/bin/env bash
set -u
auto_pid=
cleanup() {
  [ -n "$auto_pid" ] || return 0
  kill "$auto_pid" 2>/dev/null || true
  wait "$auto_pid" 2>/dev/null || true
}
trap cleanup EXIT
payload='{"session_id":"ordinary-close","stop_hook_active":true}'
printf '%s\n' "$CLAUDE_PID" > "$FM_HOME/state/.lock"

first_rc=0
printf '%s\n' "$payload" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" \
  >"$FM_HOME/state/first.out" 2>"$FM_HOME/state/first.err" || first_rc=$?
printf '%s\n' "$first_rc" > "$FM_HOME/state/first.rc"
# A normal handling turn can exceed the epoch's short duplicate-rewake window.
touch -t 202001010000 "$FM_HOME/state/.claude-autoarm-epoch"

while IFS= read -r command; do
  case "$command" in
    *fm-claude-stop-autoarm.sh*)
      printf '%s\n' "$payload" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" \
        >"$FM_HOME/state/auto.out" 2>"$FM_HOME/state/auto.err" &
      auto_pid=$!
      ;;
    *fm-turnend-guard.sh*)
      guard_rc=0
      printf '%s\n' "$payload" \
        | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=5000 "$FM_HOME/bin/fm-turnend-guard.sh" --claude \
            >"$FM_HOME/state/guard.out" 2>"$FM_HOME/state/guard.err" || guard_rc=$?
      printf '%s\n' "$guard_rc" > "$FM_HOME/state/guard.rc"
      [ "$guard_rc" -ne 2 ] || break
      ;;
  esac
done < <(jq -r '.hooks.Stop[].hooks[].command' "$REAL_SETTINGS")

if [ -n "$auto_pid" ]; then
  auto_rc=0
  wait "$auto_pid" || auto_rc=$?
  auto_pid=
  printf '%s\n' "$auto_rc" > "$FM_HOME/state/auto.rc"
else
  printf '%s\n' not-run > "$FM_HOME/state/auto.rc"
fi
SH
  chmod +x "$dispatcher"

  REAL_SETTINGS="$ROOT/.claude/settings.json" FM_HOME="$dir" "$FAKE_CLAUDE" -c \
    '"$FM_HOME/bin/ordinary-close-dispatcher.sh"'
  expect_code 2 "$(cat "$dir/state/first.rc")" "the preceding actionable cycle must close with a rewake"
  guard_rc=$(cat "$dir/state/guard.rc")
  auto_rc=$(cat "$dir/state/auto.rc")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  expect_code 0 "$guard_rc" "the ordinary-close Stop must let the auto-arm claim before the guard decides"
  expect_code 2 "$auto_rc" "the reclaimed cycle must translate its actionable close"
  [ "$count" -eq 2 ] || fail "ordinary close must arm a successor cycle, saw $count total arms"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "successful ordinary-close claim must not consume the guard budget"
  pass "auto-arm: ordinary cycle close reclaims before the synchronous guard"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "watcher cycle FAILED" "failure rewake must carry the failure banner"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_contains "$out" "repair supervision" "failure rewake must direct the manual repair"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: watcher: FAILED translates to an exit-2 alarm rewake"
}

test_clean_close_exits_silently() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a clean arm close with no actionable reason must not rewake"
  [ -z "$out" ] || fail "clean close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: clean close exits silently with a clean epoch"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$CLAUDE_PID" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

test_settings_registers_autoarm_with_multi_hour_timeout
test_inert_in_child_worktree
test_inert_without_session_lock
test_mid_session_takeover_claims_with_stable_claude_owner
test_restarted_session_hook_lane_claims_ancestral_lock_owner
test_inherited_claude_pid_does_not_override_nested_non_claude
test_nested_non_claude_lane_cannot_use_outer_claude_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_ordinary_cycle_close_rearms_before_guard
test_failed_close_rewakes_with_failure_banner
test_clean_close_exits_silently
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib

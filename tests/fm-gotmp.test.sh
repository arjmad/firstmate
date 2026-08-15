#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
TEST_TMUX_SOCKET=
# Real /tmp/fm-<id> roots minted by tests (teardown only removes that exact
# shape); space-separated, no spaces in the paths themselves.
TASK_TMPS=

cleanup() {
  local t
  if [ -n "${TEST_TMUX_SOCKET:-}" ]; then
    tmux -L "$TEST_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  for t in $TASK_TMPS; do
    rm -rf "$t"
  done
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2 target=${3:-fakeses:fm-$1} extra_meta=${4:-}
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # fm-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  # fm-session-lock-lib.sh: backends/tmux.sh sources it, a newly required
  # sibling since the session-lock ancestry work rode into the tmux adapter.
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # Lifecycle serialization and shared adapter ownership are sourced by teardown.
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-prime-tmp-lib.sh: teardown sources it for the one shared prime-agent
  # temp-root shape validator, on every task rather than only prime-agent ones.
  ln -s "$ROOT/bin/fm-prime-tmp-lib.sh" "$fake/bin/fm-prime-tmp-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=$target
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  [ -z "$extra_meta" ] || printf '%s\n' "$extra_meta" >> "$fake/state/$id.meta"
  printf '%s' "$fake"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2-$$
  local task_tmp=/tmp/fm-$id
  TASK_TMPS="$TASK_TMPS $task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  # fm-session-lock-lib.sh: backends/tmux.sh sources it, a newly required
  # sibling since the session-lock ancestry work rode into the tmux adapter.
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-prime-tmp-lib.sh: teardown sources it for the one shared prime-agent
  # temp-root shape validator, on every task rather than only prime-agent ones.
  ln -s "$ROOT/bin/fm-prime-tmp-lib.sh" "$fake/bin/fm-prime-tmp-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4-$$
  local task_tmp=/tmp/fm-$id
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_tasktmp_when_closing_own_tmux_pane() {
  command -v tmux >/dev/null 2>&1 || {
    pass "fm-teardown own-pane cleanup skipped without tmux"
    return 0
  }
  local id=td-self-tmux-z5-$$ session=fmgt deadline
  local task_tmp=/tmp/fm-$id window=fm-td-self-tmux-z5-$$ fake output="$TMP_ROOT/own-pane.out"
  # Private per-run socket: isolated from any developer/CI tmux server, and no
  # session-name collisions between concurrent runs of this suite.
  TEST_TMUX_SOCKET="fmgt$$"
  TASK_TMPS="$TASK_TMPS $task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  fake=$(make_fake_root "$id" "$task_tmp" "$session:$window")

  if ! tmux -L "$TEST_TMUX_SOCKET" new-session -d -s "$session" -n "$window" \
    "env FM_HOME='$fake' bash '$fake/bin/fm-teardown.sh' '$id' >'$output' 2>&1"; then
    TEST_TMUX_SOCKET=
    pass "fm-teardown own-pane cleanup skipped: tmux server could not start in this environment"
    return 0
  fi
  deadline=$((SECONDS + 30))
  while tmux -L "$TEST_TMUX_SOCKET" has-session -t "=$session" 2>/dev/null \
    && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.2
  done
  tmux -L "$TEST_TMUX_SOCKET" has-session -t "=$session" 2>/dev/null \
    && fail "teardown did not close its own tmux pane within 30s"
  tmux -L "$TEST_TMUX_SOCKET" kill-server 2>/dev/null || true
  TEST_TMUX_SOCKET=
  [ ! -e "$task_tmp" ] \
    || fail "teardown leaked tasktmp when its tmux kill terminated the running pane: $(cat "$output" 2>/dev/null)"
  pass "fm-teardown removes tasktmp before closing its own tmux pane"
}

test_teardown_preserves_tasktmp_when_zellij_close_kills_teardown() {
  # A zellij close-tab terminates every process in the tab, including a
  # teardown running inside it. Stub the zellij adapter's kill to SIGKILL the
  # teardown shell itself, proving task files are not removed before the close.
  local id=td-self-zellij-z8-$$ rc=0
  local task_tmp=/tmp/fm-$id fake output="$TMP_ROOT/zellij-self.out"
  TASK_TMPS="$TASK_TMPS $task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  fake=$(make_fake_root "$id" "$task_tmp" "fakezs:2" "backend=zellij
endpoint_task_id=$id
zellij_session=fakezs
zellij_tab_id=1
zellij_pane_id=2")
  cat > "$fake/bin/backends/zellij.sh" <<'SH'
fm_backend_zellij_kill() { kill -9 "$$"; }
SH

  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >"$output" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "stubbed zellij close did not terminate teardown; the fixture no longer simulates a self-pane close"
  [ -f "$task_tmp/gotmp/build-artifact" ] \
    || fail "teardown removed tasktmp before its zellij close completed: $(cat "$output" 2>/dev/null)"
  [ -f "$fake/state/$id.meta" ] \
    || fail "fixture teardown removed task metadata despite dying at the close"
  pass "fm-teardown preserves tasktmp when a zellij close terminates the running shell"
}

test_teardown_refusal_preserves_tasktmp() {
  local id=td-refuse-z6-$$
  local task_tmp=/tmp/fm-$id fake
  TASK_TMPS="$TASK_TMPS $task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'keep\n' > "$task_tmp/gotmp/build-artifact"
  fake=$(make_fake_root "$id" "$task_tmp" malformed-endpoint)

  if FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1; then
    fail "teardown accepted a malformed endpoint"
  fi
  [ -f "$task_tmp/gotmp/build-artifact" ] \
    || fail "teardown refusal changed the tasktmp"
  [ -f "$fake/state/$id.meta" ] \
    || fail "teardown refusal removed task metadata"
  pass "fm-teardown refusal preserves tasktmp and task state"
}

test_teardown_refuses_corrupt_tasktmp() {
  # A tasktmp= record that is not exactly /tmp/fm-<id> (corrupt or hostile
  # meta) must refuse before any cleanup and never be deleted.
  local id=td-badtmp-z7-$$
  local victim="$TMP_ROOT/victim-$id" fake
  mkdir -p "$victim"
  printf 'keep\n' > "$victim/precious"
  fake=$(make_fake_root "$id" "$victim")

  if FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1; then
    fail "teardown accepted a tasktmp outside the exact /tmp/fm-<id> shape"
  fi
  [ -f "$victim/precious" ] \
    || fail "teardown removed a non-conforming tasktmp path"
  [ -f "$fake/state/$id.meta" ] \
    || fail "teardown tasktmp refusal removed task metadata"
  pass "fm-teardown refuses to remove a tasktmp that is not exactly /tmp/fm-<id>"
}

test_teardown_removes_tasktmp_dir
test_teardown_removes_tasktmp_when_closing_own_tmux_pane
test_teardown_preserves_tasktmp_when_zellij_close_kills_teardown
test_teardown_refusal_preserves_tasktmp
test_teardown_refuses_corrupt_tasktmp
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing

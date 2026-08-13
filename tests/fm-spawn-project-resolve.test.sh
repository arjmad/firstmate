#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh project-dir argument resolution.
#
# These exercise resolve_project_dir_arg routing only: each successful
# resolution fails fast at the missing-brief check, which sits right after
# resolution and before any tmux/treehouse side effect, so the tests create no
# windows or worktrees. FM_SPAWN_NO_GUARD=1 keeps them off the live watcher
# guard / state. Reaching "no brief" proves resolution and the cd succeeded;
# an unknown bare name must instead fail with exit 2 and a candidate list,
# never a raw `cd:` error.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-resolve)
export FM_BACKEND=tmux

HOME_DIR="$TMP_ROOT/home"
PROJECTS_DIR="$TMP_ROOT/projects"
mkdir -p "$HOME_DIR/data" "$PROJECTS_DIR/registry"

# Upstream requires an explicit delivery contract on every ship spawn and
# refuses it before project resolution, so every case passes --mode/--yolo; the
# subject under test is still only resolve_project_dir_arg's routing.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_PROJECTS_OVERRIDE="$PROJECTS_DIR" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# A bare registered project name resolves against the home's projects/ dir and
# reaches the missing-brief check, never a raw cd death.
test_bare_name_resolves() {
  local id=nope-resolve-bare-r1 out status
  out=$(run_spawn "$id" registry codex --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "bare name with missing brief should exit non-zero"
  assert_contains "$out" "error: no brief at $HOME_DIR/data/$id/brief.md" \
    "bare name was not resolved through projects/ before the brief check"
  assert_not_contains "$out" "cd:" \
    "bare name resolution died on a raw cd error"
  pass "bare registered project name resolves to projects/<name>"
}

# The existing projects/<name> spelling keeps working exactly as before.
test_projects_prefix_resolves() {
  local id=nope-resolve-prefix-r2 out status
  out=$(run_spawn "$id" projects/registry codex --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "projects/ path with missing brief should exit non-zero"
  assert_contains "$out" "error: no brief at $HOME_DIR/data/$id/brief.md" \
    "projects/registry did not reach the brief check"
  assert_not_contains "$out" "cd:" \
    "projects/ resolution died on a raw cd error"
  pass "projects/<name> spelling still resolves as before"
}

# An unknown bare name fails with exit 2, names what was looked for, and lists
# the available project directories instead of a raw cd error.
test_unknown_bare_name_lists_candidates() {
  local id=nope-resolve-miss-r3 out status
  out=$(run_spawn "$id" registry-x codex --mode no-mistakes --yolo off)
  status=$?
  expect_code 2 "$status" "unknown bare name"
  assert_contains "$out" "no project 'registry-x' (looked in $PROJECTS_DIR/registry-x)" \
    "unknown bare name error does not name what was looked for"
  assert_contains "$out" "- registry" \
    "unknown bare name error does not list available projects"
  assert_not_contains "$out" "cd:" \
    "unknown bare name died on a raw cd error"
  pass "unknown bare name exits 2 with the candidate list"
}

# An empty project-dir arg fails with exit 2 and the candidate list instead of
# silently resolving to the projects root.
test_empty_arg_lists_candidates() {
  local id=nope-resolve-empty-r5 out status
  out=$(run_spawn "$id" '' codex --mode no-mistakes --yolo off)
  status=$?
  expect_code 2 "$status" "empty project-dir arg"
  assert_contains "$out" "no project '' (looked in $PROJECTS_DIR/)" \
    "empty arg error does not name what was looked for"
  assert_contains "$out" "- registry" \
    "empty arg error does not list available projects"
  assert_not_contains "$out" "cd:" \
    "empty arg died on a raw cd error"
  pass "empty project-dir arg exits 2 with the candidate list"
}

# '.' and '..' keep their cwd-relative meaning: they pass through untouched
# instead of resolving into the projects root via the bare-name branch.
test_dot_paths_stay_cwd_relative() {
  local id=nope-resolve-dot-r6 out status arg
  for arg in . ..; do
    out=$(cd "$TMP_ROOT" && run_spawn "$id" "$arg" codex --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "'$arg' with missing brief should exit non-zero"
    assert_contains "$out" "error: no brief at $HOME_DIR/data/$id/brief.md" \
      "'$arg' did not pass through to the brief check"
    assert_not_contains "$out" "no project" \
      "'$arg' hit the bare-name registry branch"
    assert_not_contains "$out" "cd:" \
      "'$arg' resolution died on a raw cd error"
  done
  pass "'.' and '..' keep their cwd-relative pass-through"
}

# An explicit absolute path passes through untouched and reaches the brief check.
test_explicit_path_passes_through() {
  local id=nope-resolve-abs-r4 out dir status
  dir="$TMP_ROOT/explicit-proj"
  mkdir -p "$dir"
  out=$(run_spawn "$id" "$dir" codex --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "explicit path with missing brief should exit non-zero"
  assert_contains "$out" "error: no brief at $HOME_DIR/data/$id/brief.md" \
    "explicit absolute path did not reach the brief check"
  assert_not_contains "$out" "cd:" \
    "explicit path resolution died on a raw cd error"
  pass "explicit absolute path passes through untouched"
}

test_bare_name_resolves
test_projects_prefix_resolves
test_unknown_bare_name_lists_candidates
test_empty_arg_lists_candidates
test_dot_paths_stay_cwd_relative
test_explicit_path_passes_through

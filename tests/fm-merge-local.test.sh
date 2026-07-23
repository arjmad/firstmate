#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh's guarded local-only fast-forward.
# The suite uses real temporary Git repositories and covers the successful merge
# plus refusal before mutation for the wrong delivery mode, a dirty default-branch
# checkout, and diverged task work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

make_case() {
  local name=$1 case_dir fake_root
  case_dir="$TMP_ROOT/$name"
  fake_root="$case_dir/root"
  mkdir -p "$case_dir/home/state" "$fake_root/bin"

  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
exit 7
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  : > "$case_dir/guard.log"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/seed" 2>/dev/null
  git -C "$case_dir/seed" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m baseline
  git -C "$case_dir/seed" push -q origin main
  rm -rf "$case_dir/seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "project=$case_dir/project" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$case_dir/root" \
    FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_GUARD_LOG="$case_dir/guard.log" \
    "$MERGE_LOCAL" task-x1 2>&1
}

commit_task() {
  local case_dir=$1 message=${2:-task-change}
  git -C "$case_dir/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m "$message"
}

commit_main() {
  local case_dir=$1 message=${2:-main-change}
  git -C "$case_dir/project" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m "$message"
}

test_fast_forwards_local_only_task() {
  local case_dir out rc branch_head
  case_dir=$(make_case success)
  commit_task "$case_dir"
  branch_head=$(git -C "$case_dir/project" rev-parse fm/task-x1)

  rc=0
  out=$(run_merge "$case_dir") || rc=$?

  expect_code 0 "$rc" "local-only fast-forward"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$branch_head" ] || \
    fail "local merge did not advance main to fm/task-x1"
  [ "$(git -C "$case_dir/project" rev-list --count main)" -eq 2 ] || \
    fail "local merge created an unexpected commit"
  assert_contains "$out" "merged fm/task-x1 into local main" "success output must name the merged branches"
  [ "$(wc -l < "$case_dir/guard.log" | tr -d ' ')" -eq 1 ] || fail "fm-guard.sh must run exactly once"
  pass "local-only task fast-forwards main after invoking the guard"
}

test_refuses_non_local_mode_before_mutation() {
  local case_dir before out rc
  case_dir=$(make_case wrong-mode)
  commit_task "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "project=$case_dir/project" \
    "mode=no-mistakes"

  rc=0
  out=$(run_merge "$case_dir") || rc=$?

  expect_code 1 "$rc" "non-local-only refusal"
  assert_contains "$out" "not local-only" "refusal must explain the delivery-mode mismatch"
  assert_contains "$out" "fm-pr-merge.sh" "refusal must point PR tasks at their merge authority"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] || fail "mode refusal advanced main"
  pass "non-local-only tasks are refused before Git mutation"
}

test_refuses_dirty_default_checkout() {
  local case_dir before out rc
  case_dir=$(make_case dirty)
  commit_task "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)
  printf 'uncommitted\n' > "$case_dir/project/dirty.txt"

  rc=0
  out=$(run_merge "$case_dir") || rc=$?

  expect_code 1 "$rc" "dirty checkout refusal"
  assert_contains "$out" "dirty working tree" "dirty-checkout refusal must explain the hazard"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] || fail "dirty-checkout refusal advanced main"
  assert_present "$case_dir/project/dirty.txt" "dirty-checkout refusal removed uncommitted work"
  pass "a dirty default-branch checkout is refused without touching local work"
}

test_refuses_diverged_task_branch() {
  local case_dir main_before task_before out rc
  case_dir=$(make_case diverged)
  commit_task "$case_dir" task-side
  commit_main "$case_dir" main-side
  main_before=$(git -C "$case_dir/project" rev-parse main)
  task_before=$(git -C "$case_dir/project" rev-parse fm/task-x1)

  rc=0
  out=$(run_merge "$case_dir") || rc=$?

  expect_code 1 "$rc" "diverged branch refusal"
  assert_contains "$out" "not a fast-forward" "divergence refusal must name the failed invariant"
  assert_contains "$out" "rebase" "divergence refusal must state the recovery action"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$main_before" ] || fail "divergence refusal changed main"
  [ "$(git -C "$case_dir/project" rev-parse fm/task-x1)" = "$task_before" ] || fail "divergence refusal changed the task branch"
  pass "diverged task work is refused with both branches unchanged"
}

test_fast_forwards_local_only_task
test_refuses_non_local_mode_before_mutation
test_refuses_dirty_default_checkout
test_refuses_diverged_task_branch

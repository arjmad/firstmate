#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh's scout-to-ship metadata transition.
# The suite covers preserved metadata and output on success, plus refusal without
# mutation for missing metadata and tasks that are not scouts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote)

make_case() {
  local name=$1 case_dir fake_root
  case_dir="$TMP_ROOT/$name case"
  fake_root="$case_dir/root"
  mkdir -p "$case_dir/home/state" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
exit 9
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  : > "$case_dir/guard.log"
  printf '%s\n' "$case_dir"
}

run_promote() {
  local case_dir=$1 id=${2:-scout-x1}
  FM_ROOT_OVERRIDE="$case_dir/root" \
    FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_GUARD_LOG="$case_dir/guard.log" \
    "$PROMOTE" "$id" 2>&1
}

test_promotes_scout_and_preserves_metadata() {
  local case_dir meta out rc home_q
  case_dir=$(make_case success)
  meta="$case_dir/home/state/scout-x1.meta"
  fm_write_meta "$meta" \
    "window=fm-scout-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off" \
    "custom=preserve-me" \
    "kind=stale"

  rc=0
  out=$(run_promote "$case_dir") || rc=$?

  expect_code 0 "$rc" "scout promotion"
  assert_no_grep "kind=scout" "$meta" "promotion left the scout kind in metadata"
  [ "$(grep -c '^kind=ship$' "$meta")" -eq 1 ] || fail "promotion must write exactly one kind=ship line"
  assert_grep "window=fm-scout-x1" "$meta" "promotion lost the window field"
  assert_grep "mode=no-mistakes" "$meta" "promotion lost the delivery mode"
  assert_grep "custom=preserve-me" "$meta" "promotion lost unrelated metadata"
  assert_contains "$out" "promoted scout-x1 to ship" "success output must confirm the transition"
  assert_contains "$out" "fm-send.sh fm-scout-x1" "success output must provide the next worker command"
  home_q=$(printf '%q' "$case_dir/home")
  assert_contains "$out" "FM_HOME=$home_q" "next command must safely quote FM_HOME"
  [ "$(wc -l < "$case_dir/guard.log" | tr -d ' ')" -eq 1 ] || fail "fm-guard.sh must run exactly once"
  assert_absent "$meta.tmp" "successful promotion left a temporary metadata file"
  pass "scout promotion normalizes kind and preserves unrelated metadata"
}

test_refuses_non_scout_without_mutation() {
  local case_dir meta before out rc after
  case_dir=$(make_case non-scout)
  meta="$case_dir/home/state/scout-x1.meta"
  fm_write_meta "$meta" \
    "window=fm-scout-x1" \
    "kind=ship" \
    "mode=no-mistakes"
  before=$(cat "$meta")

  rc=0
  out=$(run_promote "$case_dir") || rc=$?
  after=$(cat "$meta")

  expect_code 1 "$rc" "non-scout refusal"
  assert_contains "$out" "is not a scout task" "refusal must explain the missing scout contract"
  [ "$after" = "$before" ] || fail "non-scout refusal changed metadata"
  assert_absent "$meta.tmp" "non-scout refusal left a temporary metadata file"
  pass "non-scout tasks are refused with metadata unchanged"
}

test_refuses_missing_metadata() {
  local case_dir expected_meta out rc
  case_dir=$(make_case missing)
  expected_meta="$case_dir/home/state/missing-x2.meta"

  rc=0
  out=$(run_promote "$case_dir" missing-x2) || rc=$?

  expect_code 1 "$rc" "missing metadata refusal"
  assert_contains "$out" "no meta for task missing-x2 at $expected_meta" "missing-meta refusal must name the expected record"
  assert_absent "$expected_meta" "missing-meta refusal created metadata"
  assert_absent "$expected_meta.tmp" "missing-meta refusal left a temporary metadata file"
  pass "missing task metadata is refused without creating state"
}

test_promotes_scout_and_preserves_metadata
test_refuses_non_scout_without_mutation
test_refuses_missing_metadata

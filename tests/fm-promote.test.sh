#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh's scout-to-ship transition.
# The suite covers synchronized durable and volatile records on success, plus
# refusal without mutation for invalid metadata or an unusable backlog backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

make_case() {
  local name=$1 case_dir fake_root
  case_dir="$TMP_ROOT/$name case"
  fake_root="$case_dir/root"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
exit 9
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  : > "$case_dir/guard.log"
  printf '%s\n' "$case_dir"
}

write_scout_meta() {
  local case_dir=$1
  fm_write_meta "$case_dir/home/state/scout-x1.meta" \
    "window=fm-scout-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off" \
    "custom=preserve-me" \
    "kind=stale"
}

add_backlog_task() {
  local case_dir=$1 id=${2:-scout-x1} kind=${3:-scout}
  "$TASKS_AXI_BIN" add "$id" "Investigate sample systems" \
    --kind "$kind" --repo sample --start \
    --file "$case_dir/home/data/backlog.md" >/dev/null
}

run_promote() {
  local case_dir=$1 id=${2:-scout-x1}
  PATH="${FM_TEST_PATH:-$PATH}" \
    FM_ROOT_OVERRIDE="$case_dir/root" \
    FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_TEST_GUARD_LOG="$case_dir/guard.log" \
    "$PROMOTE" "$id" 2>&1
}

test_promotes_scout_and_updates_backlog() {
  local case_dir meta backlog out rc home_q shown
  [ -n "$TASKS_AXI_BIN" ] || { pass "scout promotion success case skipped without tasks-axi"; return; }
  case_dir=$(make_case success)
  meta="$case_dir/home/state/scout-x1.meta"
  backlog="$case_dir/home/data/backlog.md"
  write_scout_meta "$case_dir"
  add_backlog_task "$case_dir"

  rc=0
  out=$(run_promote "$case_dir") || rc=$?

  expect_code 0 "$rc" "scout promotion"
  assert_no_grep "kind=scout" "$meta" "promotion left the scout kind in metadata"
  [ "$(grep -c '^kind=ship$' "$meta")" -eq 1 ] || fail "promotion must write exactly one kind=ship line"
  assert_grep "window=fm-scout-x1" "$meta" "promotion lost the window field"
  assert_grep "mode=no-mistakes" "$meta" "promotion lost the delivery mode"
  assert_grep "custom=preserve-me" "$meta" "promotion lost unrelated metadata"
  assert_grep "(kind: ship)" "$backlog" "promotion left the durable backlog kind as scout"
  shown=$("$TASKS_AXI_BIN" show scout-x1 --file "$backlog") || fail "promoted backlog record could not be read"
  assert_contains "$shown" "kind: ship" "tasks-axi did not read the promoted record as ship"
  assert_contains "$out" "promoted scout-x1 to ship" "success output must confirm the transition"
  assert_contains "$out" "durable backlog updated" "success output must confirm the durable update"
  assert_contains "$out" "fm-send.sh fm-scout-x1" "success output must provide the next worker command"
  home_q=$(printf '%q' "$case_dir/home")
  assert_contains "$out" "FM_HOME=$home_q" "next command must safely quote FM_HOME"
  [ "$(wc -l < "$case_dir/guard.log" | tr -d ' ')" -eq 1 ] || fail "fm-guard.sh must run exactly once"
  assert_absent "$meta.tmp" "successful promotion left a temporary metadata file"
  pass "scout promotion updates durable and volatile kinds together"
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
  case_dir=$(make_case missing-meta)
  expected_meta="$case_dir/home/state/missing-x2.meta"

  rc=0
  out=$(run_promote "$case_dir" missing-x2) || rc=$?

  expect_code 1 "$rc" "missing metadata refusal"
  assert_contains "$out" "no meta for task missing-x2 at $expected_meta" "missing-meta refusal must name the expected record"
  assert_absent "$expected_meta" "missing-meta refusal created metadata"
  assert_absent "$expected_meta.tmp" "missing-meta refusal left a temporary metadata file"
  pass "missing task metadata is refused without creating state"
}

test_refuses_missing_backlog_record_without_mutation() {
  local case_dir meta before out rc after
  [ -n "$TASKS_AXI_BIN" ] || { pass "missing backlog record case skipped without tasks-axi"; return; }
  case_dir=$(make_case missing-backlog)
  meta="$case_dir/home/state/scout-x1.meta"
  write_scout_meta "$case_dir"
  add_backlog_task "$case_dir" other-x2 ship
  before=$(cat "$meta")

  rc=0
  out=$(run_promote "$case_dir") || rc=$?
  after=$(cat "$meta")

  expect_code 1 "$rc" "missing backlog record refusal"
  assert_contains "$out" "no durable backlog record for task scout-x1" "missing backlog refusal must identify the absent durable record"
  [ "$after" = "$before" ] || fail "missing backlog record refusal changed metadata"
  assert_no_grep "scout-x1" "$case_dir/home/data/backlog.md" "missing backlog refusal created a durable record"
  assert_absent "$meta.tmp" "missing backlog refusal left a temporary metadata file"
  pass "missing durable backlog records are refused without metadata mutation"
}

test_refuses_manual_backend_without_mutation() {
  local case_dir meta backlog meta_before backlog_before out rc
  [ -n "$TASKS_AXI_BIN" ] || { pass "manual backend case skipped without tasks-axi"; return; }
  case_dir=$(make_case manual-backend)
  meta="$case_dir/home/state/scout-x1.meta"
  backlog="$case_dir/home/data/backlog.md"
  write_scout_meta "$case_dir"
  add_backlog_task "$case_dir"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  meta_before=$(cat "$meta")
  backlog_before=$(cat "$backlog")

  rc=0
  out=$(run_promote "$case_dir") || rc=$?

  expect_code 1 "$rc" "manual backend refusal"
  assert_contains "$out" "config/backlog-backend selects manual" "manual backend refusal must name the selected backend"
  [ "$(cat "$meta")" = "$meta_before" ] || fail "manual backend refusal changed metadata"
  [ "$(cat "$backlog")" = "$backlog_before" ] || fail "manual backend refusal changed the backlog"
  assert_absent "$meta.tmp" "manual backend refusal left a temporary metadata file"
  pass "manual backlog mode refuses promotion without partial mutation"
}

test_refuses_unavailable_backend_without_mutation() {
  local case_dir meta backlog fakebin meta_before backlog_before out rc
  [ -n "$TASKS_AXI_BIN" ] || { pass "unavailable backend case skipped without tasks-axi fixture setup"; return; }
  case_dir=$(make_case unavailable-backend)
  meta="$case_dir/home/state/scout-x1.meta"
  backlog="$case_dir/home/data/backlog.md"
  fakebin=$(fm_fakebin "$case_dir")
  write_scout_meta "$case_dir"
  add_backlog_task "$case_dir"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$fakebin/tasks-axi"
  meta_before=$(cat "$meta")
  backlog_before=$(cat "$backlog")

  rc=0
  FM_TEST_PATH="$fakebin:$PATH" out=$(run_promote "$case_dir") || rc=$?

  expect_code 1 "$rc" "unavailable backend refusal"
  assert_contains "$out" "tasks-axi backlog backend is unavailable or incompatible" "unavailable backend refusal must name the backend problem"
  [ "$(cat "$meta")" = "$meta_before" ] || fail "unavailable backend refusal changed metadata"
  [ "$(cat "$backlog")" = "$backlog_before" ] || fail "unavailable backend refusal changed the backlog"
  assert_absent "$meta.tmp" "unavailable backend refusal left a temporary metadata file"
  pass "unavailable backlog backend refuses promotion without partial mutation"
}

test_promotes_scout_and_updates_backlog
test_refuses_non_scout_without_mutation
test_refuses_missing_metadata
test_refuses_missing_backlog_record_without_mutation
test_refuses_manual_backend_without_mutation
test_refuses_unavailable_backend_without_mutation

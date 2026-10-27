#!/usr/bin/env bash
# Tests for bin/fm-capture-land.sh: landing one skill-capture PR end to end.
# A copied bin/ keeps the real record, backlog, and teardown path while
# bin/fm-pr-merge.sh and bin/fm-fleet-sync.sh are stubs that log their calls,
# and a fake gh serves the pull request, so each case asserts what was
# refused, recorded, merged, settled, and closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v tasks-axi >/dev/null 2>&1 || fail "these tests file backlog items with tasks-axi, which was not found"
TMP_ROOT=$(fm_test_tmproot fm-capture-land-tests)
URL=https://github.com/arjmad/nova/pull/266
HEAD_SHA=1111111111111111111111111111111111111111
OTHER_SHA=2222222222222222222222222222222222222222
ID=capture-nova-266

# new_case: a code root with stubbed merge and sync, a home whose nova project
# is a capture project, and a fake gh serving an open, current capture PR.
# Echoes the case directory.
new_case() {
  local c
  c=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$c/code" "$c/home/config" "$c/home/data" "$c/home/state" "$c/home/projects" "$c/fakebin"
  cp -R "$ROOT/bin" "$c/code/bin"
  cat > "$c/code/bin/fm-pr-merge.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> '$c/merge.log'
cp "\$FM_HOME/state/\$1.meta" '$c/meta-at-merge' 2>/dev/null || true
exit "\$(cat '$c/merge-rc' 2>/dev/null || echo 0)"
STUB
  cat > "$c/code/bin/fm-fleet-sync.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> '$c/sync.log'
[ "\${1:-}" != --settle-capture ] || cat '$c/sync-out' 2>/dev/null || true
STUB
  chmod +x "$c/code/bin/fm-pr-merge.sh" "$c/code/bin/fm-fleet-sync.sh"
  cat > "$c/fakebin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> '$c/gh.log'
case "\$1 \$2" in
  "pr view") case "\$*" in
      *"-q .headRefOid"*) echo $HEAD_SHA ;;
      *"--jq .state") cat '$c/state-after-merge' 2>/dev/null || echo MERGED ;;
      *) cat '$c/pr.tsv' ;;
    esac ;;
  "api repos/arjmad/nova") echo main ;;
  "api repos/arjmad/nova/compare/"*) cat '$c/behind' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$c/fakebin/gh"
  git init -q "$c/home/projects/nova"
  git -C "$c/home/projects/nova" remote add origin git@github.com:arjmad/nova.git
  git init -q "$c/home/projects/other"
  git -C "$c/home/projects/other" remote add origin https://github.com/arjmad/other.git
  printf '%s\n' "nova ~/code/agents/nova capture=skills/:cron/skill-capture.sh echo post" \
    "other ~/code/other" > "$c/home/config/live-checkouts"
  fm_test_tasks_toml "$c/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$c/home/data/backlog.md"
  set_pr "$c" OPEN false nova/skill-capture "$HEAD_SHA"
  echo 0 > "$c/behind"
  echo "nova live ~/code/agents/nova: synced abc..def" > "$c/sync-out"
  printf '%s\n' "$c"
}

# set_pr <case> <state> <draft> <head-branch> <head-sha> [cross-repo]
set_pr() {
  printf '%s\t%s\t%s\tmain\t%s\t%s\n' "$2" "$3" "$4" "$5" "${6:-false}" > "$1/pr.tsv"
}

# land <case> [args...]: run the command; output in $OUT, exit in $RC.
land() {
  local c=$1
  shift
  RC=0
  OUT=$(PATH="$c/fakebin:$PATH" FM_HOME="$c/home" "$c/code/bin/fm-capture-land.sh" "$@" 2>&1) || RC=$?
}

backlog_section_of() {  # <case> <id>: the backlog section holding the item
  awk -v id="$2" '/^## /{s=$0} index($0, id) {print s; exit}' "$1/home/data/backlog.md"
}

test_lands_an_open_capture_pr_end_to_end() {
  local c
  c=$(new_case)
  land "$c" "$URL" --head "$HEAD_SHA"
  assert_equals 0 "$RC" "an open green capture PR lands: $OUT"
  assert_equals "$ID $URL" "$(cat "$c/merge.log")" "the merge goes through bin/fm-pr-merge.sh with the task record"
  grep -qx 'worktree=' "$c/meta-at-merge" || fail "the record names no worktree"
  grep -qxF "project=$c/home/projects/nova" "$c/meta-at-merge" || fail "the record names the capture project"
  grep -qxF "capture_land=$URL" "$c/meta-at-merge" || fail "the record is marked as this command's"
  assert_equals "--settle-capture $c/home/projects/nova" "$(head -1 "$c/sync.log")" "the live checkout is settled through fleet sync"
  assert_absent "$c/home/state/$ID.meta" "the record is closed"
  assert_equals "## Done" "$(backlog_section_of "$c" "$ID")" "the backlog item is Done"
  assert_contains "$OUT" "landed: $URL" "the outcome is reported"
  pass "an open capture PR is recorded, merged, settled, synced, and closed"
}

test_refuses_a_pr_that_is_not_a_capture_pr() {
  local c
  c=$(new_case)
  set_pr "$c" OPEN false fm/feature "$HEAD_SHA"
  land "$c" "$URL"
  assert_equals 1 "$RC" "a non-capture branch is refused"
  assert_contains "$OUT" "not arjmad/nova's capture branch nova/skill-capture" "the refusal names the branch rule"
  set_pr "$c" OPEN false nova/skill-capture "$HEAD_SHA" true
  land "$c" "$URL"
  assert_equals 1 "$RC" "a fork's capture-named branch is refused"
  land "$c" https://github.com/arjmad/other/pull/3
  assert_equals 1 "$RC" "a repository with no capture= entry is refused"
  assert_contains "$OUT" "no capture project's origin" "the refusal names the capture-project rule"
  land "$c" https://github.com/someone/nova/pull/266
  assert_equals 1 "$RC" "a same-named repository of another owner is refused"
  assert_absent "$c/merge.log" "nothing was merged"
  assert_absent "$c/home/state/$ID.meta" "nothing was recorded"
  assert_equals "" "$(backlog_section_of "$c" "$ID")" "nothing was filed"
  pass "only a capture project's own capture branch lands"
}

test_refuses_a_stale_or_draft_pr_before_recording() {
  local c
  c=$(new_case)
  land "$c" "$URL" --head "$OTHER_SHA"
  assert_equals 1 "$RC" "a head other than the noted one is refused"
  assert_contains "$OUT" "is stale: its head is $HEAD_SHA, not $OTHER_SHA" "the refusal names both heads"
  echo 2 > "$c/behind"
  land "$c" "$URL"
  assert_equals 1 "$RC" "a head behind the base is refused"
  assert_contains "$OUT" "2 commit(s) behind main" "the refusal says how far behind"
  echo 0 > "$c/behind"
  set_pr "$c" OPEN true nova/skill-capture "$HEAD_SHA"
  land "$c" "$URL"
  assert_equals 1 "$RC" "a draft is refused"
  set_pr "$c" CLOSED false nova/skill-capture "$HEAD_SHA"
  land "$c" "$URL"
  assert_equals 1 "$RC" "a closed PR is refused"
  assert_absent "$c/merge.log" "nothing was merged"
  assert_absent "$c/home/state/$ID.meta" "nothing was recorded"
  pass "a stale, draft, or closed PR is refused before anything is recorded"
}

test_refused_merge_keeps_the_record_and_a_rerun_lands() {
  local c
  c=$(new_case)
  echo 1 > "$c/merge-rc"
  land "$c" "$URL"
  assert_equals 1 "$RC" "a merge the guarded script refuses is not landed"
  assert_contains "$OUT" "not landed: bin/fm-pr-merge.sh refused $URL" "the refusal is reported"
  assert_present "$c/home/state/$ID.meta" "the record stays for the re-run"
  assert_equals "## In flight" "$(backlog_section_of "$c" "$ID")" "the backlog item stays in flight"
  assert_absent "$c/sync.log" "nothing is settled before a merge"
  echo 0 > "$c/merge-rc"
  land "$c" "$URL"
  assert_equals 0 "$RC" "the re-run lands: $OUT"
  assert_contains "$OUT" "record: reusing task $ID" "the re-run reuses the record"
  assert_equals 2 "$(wc -l < "$c/merge.log" | tr -d ' ')" "the merge was tried twice"
  assert_equals 1 "$(grep -c "$ID" "$c/home/data/backlog.md")" "one backlog item"
  assert_absent "$c/home/state/$ID.meta" "the record is closed"
  pass "a refused merge leaves the record in flight and a re-run lands it"
}

test_merged_pr_settles_and_closes_without_merging() {
  local c
  c=$(new_case)
  set_pr "$c" MERGED false nova/skill-capture "$HEAD_SHA"
  land "$c" "$URL"
  assert_equals 0 "$RC" "an already merged capture PR finishes: $OUT"
  assert_absent "$c/merge.log" "a merged PR is not merged again"
  assert_present "$c/sync.log" "a merged PR is still settled and synced"
  assert_absent "$c/home/state/$ID.meta" "a merged PR leaves no record"
  pass "a re-run on a merged capture PR settles and syncs without merging"
}

test_stuck_settle_reports_after_landing() {
  local c
  c=$(new_case)
  echo "nova live ~/code/agents/nova: STUCK: cron/skill-capture.sh --settle failed (exit 1) - needs attention" > "$c/sync-out"
  land "$c" "$URL"
  assert_equals 3 "$RC" "a landed PR whose checkout did not settle exits 3"
  assert_contains "$OUT" "did not settle and go live" "the unfinished settle is reported"
  assert_absent "$c/home/state/$ID.meta" "the landed record is still closed"
  pass "a landed PR whose live checkout did not settle exits 3 for a re-run"
}

test_unsynced_live_checkout_is_unfinished() {
  local c line
  for line in "skipped: fetch failed" "capturing: 1 uncommitted path(s) under skills/ only; started x" ""; do
    c=$(new_case)
    if [ -n "$line" ]; then echo "nova live ~/code/agents/nova: $line" > "$c/sync-out"; else : > "$c/sync-out"; fi
    land "$c" "$URL"
    assert_equals 3 "$RC" "a live checkout that did not end synced is unfinished (${line:-no line}): $OUT"
  done
  pass "only a live checkout that ends synced counts as live"
}

test_queued_merge_keeps_the_record() {
  local c
  c=$(new_case)
  echo OPEN > "$c/state-after-merge"
  land "$c" "$URL"
  assert_equals 3 "$RC" "a queued merge is not landed yet"
  assert_contains "$OUT" "queued: $URL is not merged yet" "the queue is reported"
  assert_absent "$c/sync.log" "nothing is settled before the merge lands"
  assert_present "$c/home/state/$ID.meta" "the record and its poll stay"
  pass "a merge the queue accepted but has not merged keeps the record"
}

test_foreign_record_is_never_reused() {
  local c
  c=$(new_case)
  printf 'window=x:fm-%s\nkind=ship\n' "$ID" > "$c/home/state/$ID.meta"
  land "$c" "$URL"
  assert_equals 1 "$RC" "a record this command did not write is refused"
  assert_contains "$OUT" "is not this command's record" "the refusal names the record"
  assert_absent "$c/merge.log" "nothing was merged"
  pass "an unrelated task record with the same id is never reused"
}

test_merge_time_record_reads_the_head_without_a_worktree() {
  local c out
  c=$(new_case)
  echo 1 > "$c/merge-rc"
  land "$c" "$URL"
  out=$(PATH="$c/fakebin:$PATH" FM_HOME="$c/home" "$c/code/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1) \
    && fail "an arming pr-check on a record with no worktree must still refuse: $out"
  assert_contains "$out" "worktree missing" "an ordinary ready report still needs its worktree"
  out=$(PATH="$c/fakebin:$PATH" FM_HOME="$c/home" FM_PR_CHECK_MERGE=1 "$c/code/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1) \
    || fail "the merge-time record must accept the forge head: $out"
  grep -qxF "pr=$URL" "$c/home/state/$ID.meta" || fail "pr= is recorded"
  grep -qxF "pr_head=$HEAD_SHA" "$c/home/state/$ID.meta" || fail "the forge head is recorded without a worktree"
  pass "bin/fm-pr-check.sh reads the forge head for a merge-time record that names no worktree"
}

test_lands_an_open_capture_pr_end_to_end
test_merge_time_record_reads_the_head_without_a_worktree
test_refuses_a_pr_that_is_not_a_capture_pr
test_refuses_a_stale_or_draft_pr_before_recording
test_refused_merge_keeps_the_record_and_a_rerun_lands
test_merged_pr_settles_and_closes_without_merging
test_stuck_settle_reports_after_landing
test_unsynced_live_checkout_is_unfinished
test_queued_merge_keeps_the_record
test_foreign_record_is_never_reused

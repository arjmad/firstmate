#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-decisions.sh: the repository's fork-decision
# records pass the check, a decision or row appended to the docs/fork-decisions.md
# entry point fails it, malformed records fail it, a carried row naming a
# missing repository path fails it, `patches` names each record's PR from its
# `PR:` line or from the squash commit that added it, and `pr-check` fails a
# change to an upstream-owned file that adds no record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-fork-decisions.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-decisions)
HEADER='| What | Files or functions | Upstream code touched | Status | Last checked sync |'

run_expect_failure() {
  local expected=$1 out rc
  shift
  out=$("$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected', got success: $out"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

# A fixture repository with an entry point, one decision record and one
# migrated fork-patch record, committed.
# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
fixture() {
  local repo=$1
  fm_git_init_commit "$repo"
  mkdir -p "$repo/docs/fork-decisions"
  printf '# Fork decisions\n\nRecords live under docs/fork-decisions/.\n' > "$repo/docs/fork-decisions.md"
  printf '2026-10-01: Arjun decided to keep it.\nNo upstream proposal.\n' \
    > "$repo/docs/fork-decisions/2026-10-01-keep-it.md"
  printf 'PR: #7\n\n%s\n| --- | --- | --- | --- | --- |\n| Fix a thing | `bin/a.sh` | same file | carried | abc123 |\n' "$HEADER" \
    > "$repo/docs/fork-decisions/2026-10-02-fix-a-thing.md"
  git -C "$repo" add docs
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'Seed fork decisions (#5)'
}

test_repository_records_pass() {
  local out
  out=$("$SCRIPT" check) || fail "the repository's fork-decision records failed the check"
  assert_contains "$out" "fm-fork-decisions: ok records=" "the check did not report its record count"
  pass "the repository's fork-decision records pass the check"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
test_appending_to_the_entry_point_fails() {
  local repo="$TMP_ROOT/append-decision" repo_row="$TMP_ROOT/append-row"
  fixture "$repo"
  "$SCRIPT" check --root "$repo" >/dev/null || fail "the fixture should pass before the append"
  printf '\n2026-10-26: Arjun decided something new.\n' >> "$repo/docs/fork-decisions.md"
  run_expect_failure "docs/fork-decisions.md:5: a decision or fork-patch row belongs in its own file" \
    "$SCRIPT" check --root "$repo"
  fixture "$repo_row"
  printf '\n| 2026-10-26 | #120 | Another fix | `bin/b.sh` | same file | carried | abc123 |\n' >> "$repo_row/docs/fork-decisions.md"
  run_expect_failure "docs/fork-decisions.md:5: a decision or fork-patch row belongs in its own file" \
    "$SCRIPT" check --root "$repo_row"
  pass "a dated decision or a table row appended to the entry point fails the check"
}

test_malformed_records_fail() {
  local repo="$TMP_ROOT/malformed"
  fixture "$repo"
  printf '2026-10-03: A decision.\n' > "$repo/docs/fork-decisions/Notes.md"
  run_expect_failure "docs/fork-decisions/Notes.md: a record is a file named <YYYY-MM-DD>-<slug>.md" \
    "$SCRIPT" check --root "$repo"
  rm "$repo/docs/fork-decisions/Notes.md"
  printf 'Arjun decided, but the date is missing.\n' > "$repo/docs/fork-decisions/2026-10-03-undated.md"
  run_expect_failure 'docs/fork-decisions/2026-10-03-undated.md:1: a record opens with "2026-10-03: "' \
    "$SCRIPT" check --root "$repo"
  rm "$repo/docs/fork-decisions/2026-10-03-undated.md"
  printf '%s\n| --- | --- | --- | --- | --- |\n| Too few | cells |\n' "$HEADER" > "$repo/docs/fork-decisions/2026-10-03-short-row.md"
  run_expect_failure "docs/fork-decisions/2026-10-03-short-row.md:3: a fork-patch row has 5 cells, found 2" \
    "$SCRIPT" check --root "$repo"
  rm "$repo/docs/fork-decisions/2026-10-03-short-row.md"
  printf '| Date | PR | What |\n| --- | --- | --- |\n| 2026-10-03 | #9 | Old shape |\n' > "$repo/docs/fork-decisions/2026-10-03-old-shape.md"
  run_expect_failure "docs/fork-decisions/2026-10-03-old-shape.md:1: a fork-patch table opens with:" \
    "$SCRIPT" check --root "$repo"
  rm "$repo/docs/fork-decisions/2026-10-03-old-shape.md"
  printf '2026-13-40: A decision.\n' > "$repo/docs/fork-decisions/2026-13-40-impossible.md"
  run_expect_failure "docs/fork-decisions/2026-13-40-impossible.md: a record is a file named <YYYY-MM-DD>-<slug>.md with a real date" \
    "$SCRIPT" check --root "$repo"
  rm "$repo/docs/fork-decisions/2026-13-40-impossible.md"
  printf '%s\n| --- | --- | --- | --- | --- |\n| Typo | a | b | upstreamd | abc123 |\n' "$HEADER" > "$repo/docs/fork-decisions/2026-10-03-typo.md"
  run_expect_failure 'docs/fork-decisions/2026-10-03-typo.md:3: status is carried, upstreamed, conflicted, or a note saying what it is superseded by, not "upstreamd"' \
    "$SCRIPT" check --root "$repo"
  pass "a misnamed, impossibly dated, undated, short-row, wrong-header, or mistyped-status record fails the check"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
test_tolerated_record_shapes_pass() {
  local repo="$TMP_ROOT/tolerated" out
  fixture "$repo"
  : > "$repo/docs/fork-decisions/.DS_Store"
  printf 'PR: #8\n\n2026-10-03: Arjun decided, with a PR line first.\n' > "$repo/docs/fork-decisions/2026-10-03-pr-line-first.md"
  printf '%s  \n| --- | --- | --- | --- | --- |\n|  Owner `a\\|b`  |  x |  y | palette superseded by #9 | abc123 |  \n' "$HEADER" \
    > "$repo/docs/fork-decisions/2026-10-04-loose-row.md"
  out=$("$SCRIPT" check --root "$repo") || fail "a hidden file, a PR line before a decision, or loose row spacing failed the check"
  assert_contains "$out" "records=4 patches=2" "the hidden file was counted as a record"
  out=$("$SCRIPT" patches --root "$repo")
  assert_contains "$out" '| 2026-10-04 | pending | Owner `a\|b` | x | y | palette superseded by #9 | abc123 |' \
    "an escaped pipe or loose spacing changed the rendered row"
  pass "hidden files, a PR line before a decision, escaped pipes, and loose spacing pass"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
test_patches_reads_the_pr_from_the_record_or_its_commit() {
  local repo="$TMP_ROOT/patches" out
  fixture "$repo"
  printf '2026-10-04: Arjun decided a new fix.\n\n%s\n| --- | --- | --- | --- | --- |\n| New fix | `bin/c.sh` | same file | carried | abc123 |\n' "$HEADER" \
    > "$repo/docs/fork-decisions/2026-10-04-new-fix.md"
  out=$("$SCRIPT" patches --root "$repo")
  assert_contains "$out" '| 2026-10-02 | #7 | Fix a thing | `bin/a.sh` | same file | carried | abc123 |' \
    "a migrated record's PR line was not used"
  assert_contains "$out" '| 2026-10-04 | pending | New fix |' "an uncommitted record did not read as pending"
  assert_not_contains "$out" "Arjun decided" "a decision's prose leaked into the patch table"
  git -C "$repo" add docs
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'Record the new fix (#12)'
  out=$("$SCRIPT" patches --root "$repo")
  assert_contains "$out" '| 2026-10-04 | #12 | New fix | `bin/c.sh` | same file | carried | abc123 |' \
    "a new record's PR was not read from the commit that added it"
  "$SCRIPT" check --root "$repo" >/dev/null || fail "a record holding a decision and a table failed the check"

  git -C "$repo" mv docs/fork-decisions/2026-10-04-new-fix.md docs/fork-decisions/2026-10-04-renamed-fix.md
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'Rename a record (#13)'
  out=$("$SCRIPT" patches --root "$repo")
  assert_contains "$out" '| 2026-10-04 | #12 | New fix |' "a renamed record credited the renaming PR"

  git -C "$repo" checkout -qb feature
  printf '%s\n| --- | --- | --- | --- | --- |\n| Merged fix | `bin/d.sh` | same file | carried | abc123 |\n' "$HEADER" \
    > "$repo/docs/fork-decisions/2026-10-05-merged-fix.md"
  git -C "$repo" add docs
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'Record the merged fix'
  git -C "$repo" checkout -q main
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid merge -q --no-ff -m 'Merge pull request #14 from owner/feature' feature
  out=$("$SCRIPT" patches --root "$repo")
  assert_contains "$out" '| 2026-10-05 | #14 | Merged fix |' "a record landed by a merge commit did not name its PR"
  pass "patches names each PR from the record's PR line or the commit that landed it, across renames and merge commits"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm "$2"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
test_cited_paths_must_exist() {
  local repo="$TMP_ROOT/cited" record
  fixture "$repo"
  mkdir -p "$repo/bin"
  : > "$repo/bin/a.sh"; : > "$repo/bin/kept.sh"; : > "$repo/bin/tool-auth.py"
  commit_all "$repo" 'Add bin'
  record="$repo/docs/fork-decisions/2026-10-06-cited.md"
  {
    printf '%s\n| --- | --- | --- | --- | --- |\n' "$HEADER"
    printf '| Kept | `bin/kept.sh` (`main`), `bin/tool*.{sh,py}`, `state/runtime.log` | same | carried | abc123 |\n'
    printf '| Dropped a workflow | `bin/gone.yml` (removed) | that file | carried | abc123 |\n'
    printf '| Old | `bin/retired.sh` | same | superseded by #9 | abc123 |\n'
  } > "$record"
  "$SCRIPT" check --root "$repo" >/dev/null \
    || fail "an existing path, a matching glob or brace group, a (removed) path, a runtime path, or a superseded row failed the check"
  {
    printf '| Moved | `bin/kept.sh`, `bin/moved.sh` | same | conflicted | abc123 |\n'
    printf '| No match | `bin/none*.{sh,py}` | same | carried | abc123 |\n'
  } >> "$record"
  run_expect_failure 'docs/fork-decisions/2026-10-06-cited.md:6: a conflicted row names bin/moved.sh, which is not in the repository' \
    "$SCRIPT" check --root "$repo"
  run_expect_failure 'docs/fork-decisions/2026-10-06-cited.md:7: a carried row names bin/none*.{sh,py}, which is not in the repository' \
    "$SCRIPT" check --root "$repo"
  pass "a carried or conflicted row naming a missing repository path fails; globs, (removed), runtime paths, and other statuses pass"
}

# A fixture with an upstream commit holding bin/up.sh and a record naming it
# as the last checked sync, then a branch for each change under test.
# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
pr_fixture() {
  local repo=$1 sync
  fixture "$repo"
  mkdir -p "$repo/bin"
  printf 'upstream\n' > "$repo/bin/up.sh"
  commit_all "$repo" 'Upstream code'
  sync=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n| --- | --- | --- | --- | --- |\n| A patch | `bin/up.sh` | same file | carried | %s |\n' "$HEADER" "${sync:0:8}" \
    > "$repo/docs/fork-decisions/2026-10-06-a-patch.md"
  commit_all "$repo" 'Record a patch (#20)'
}

# shellcheck disable=SC2016 # Backticks are literal Markdown in the records.
test_pr_check_needs_a_record_for_upstream_owned_changes() {
  local repo="$TMP_ROOT/pr-check" out
  pr_fixture "$repo"

  git -C "$repo" checkout -qb fork-only main
  printf 'fork\n' > "$repo/bin/fork-only.sh"
  printf '\nMore fork prose.\n' >> "$repo/docs/fork-decisions.md"
  commit_all "$repo" 'Fork-only change'
  out=$("$SCRIPT" pr-check --root "$repo" --base main --head fork-only) \
    || fail "a change to fork-owned files only failed pr-check: $out"
  assert_contains "$out" "pr-check ok upstream-owned=0 records=0" "pr-check did not report the fork-only change"

  git -C "$repo" checkout -qb unrecorded main
  printf 'patched\n' >> "$repo/bin/up.sh"
  commit_all "$repo" 'Patch upstream code'
  run_expect_failure "edits upstream-owned files (present at upstream sync" \
    "$SCRIPT" pr-check --root "$repo" --base main --head unrecorded
  out=$("$SCRIPT" pr-check --root "$repo" --base main --head unrecorded 2>&1) || true
  assert_contains "$out" "  bin/up.sh" "pr-check did not name the upstream-owned file"

  git -C "$repo" checkout -qb recorded unrecorded
  printf '%s\n| --- | --- | --- | --- | --- |\n| Patch it | `bin/up.sh` | same file | carried | abc123 |\n' "$HEADER" \
    > "$repo/docs/fork-decisions/2026-10-07-patch-it.md"
  commit_all "$repo" 'Record the patch'
  out=$("$SCRIPT" pr-check --root "$repo" --base main --head recorded) \
    || fail "an upstream-owned change with its record failed pr-check: $out"
  assert_contains "$out" "pr-check ok upstream-owned=1 records=1" "pr-check did not count the change and its record"

  git -C "$repo" checkout -q recorded
  out=$("$SCRIPT" pr-check --root "$repo" --base main) || fail "pr-check with the default --head failed: $out"

  run_expect_failure "pr-check needs --base" "$SCRIPT" pr-check --root "$repo"
  run_expect_failure "--base needs a revision and belongs to pr-check" "$SCRIPT" check --root "$repo" --base main
  pass "pr-check fails an upstream-owned change without a record and passes fork-only or recorded changes"
}

test_repository_records_pass
test_appending_to_the_entry_point_fails
test_malformed_records_fail
test_tolerated_record_shapes_pass
test_patches_reads_the_pr_from_the_record_or_its_commit
test_cited_paths_must_exist
test_pr_check_needs_a_record_for_upstream_owned_changes

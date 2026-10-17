#!/usr/bin/env bash
# Tests for bin/fm-code-review.sh: the code-changing classifier, the review
# status of a GitHub pull request, and the record that marks one reviewed,
# driven through the public entrypoint against a faked gh that applies its
# --jq filters with the real jq.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CODE_REVIEW="$ROOT/bin/fm-code-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-code-review-tests)
command -v jq >/dev/null 2>&1 || fail "these tests apply gh's --jq filters with the real jq, which was not found"
URL=https://github.com/example/repo/pull/12
HEAD_SHA=1234567890abcdef1234567890abcdef12345678

# A fixture directory holding the PR's files, diff, comments, and head, and a
# fake gh over it. `gh pr comment` appends an OWNER comment, as the
# authenticated repository owner's comment reads back. Args: name path...
make_case() {
  local name=$1 dir
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename: .})' > "$dir/files.json"
  printf '%s\n' '[]' > "$dir/comments.json"
  printf '%s\n' "$HEAD_SHA" > "$dir/head"
  cat > "$dir/diff" <<'DIFF'
diff --git a/bin/tool.sh b/bin/tool.sh
index 1111111..2222222 100755
--- a/bin/tool.sh
+++ b/bin/tool.sh
@@ -1,2 +1,2 @@
 #!/usr/bin/env bash
-echo old
+echo new
DIFF
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_DIR/gh.log"
gh_jq() {
  local prev='' arg filter='.'
  for arg in "${@:2}"; do
    [ "$prev" != --jq ] || filter=$arg
    prev=$arg
  done
  jq -r "$filter" "$1"
}
case "$1 $2" in
  "api --paginate")
    case "$3" in
      repos/example/repo/pulls/12/files)
        [ ! -f "$FM_TEST_DIR/files-fail" ] || exit 1
        gh_jq "$FM_TEST_DIR/files.json" "$@"
        ;;
      repos/example/repo/issues/12/comments) gh_jq "$FM_TEST_DIR/comments.json" "$@" ;;
      *) exit 1 ;;
    esac
    ;;
  "pr diff") cat "$FM_TEST_DIR/diff" ;;
  "pr view") cat "$FM_TEST_DIR/head" ;;
  "pr comment")
    [ ! -f "$FM_TEST_DIR/comment-fail" ] || exit 1
    body=$(cat)
    jq -c --arg b "$body" '. + [{author_association: "OWNER", body: $b}]' "$FM_TEST_DIR/comments.json" \
      > "$FM_TEST_DIR/comments.next" && mv "$FM_TEST_DIR/comments.next" "$FM_TEST_DIR/comments.json"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

# Runs the script against a case. Args: dir args...; sets RC, OUT, ERR.
run_case() {
  local dir=$1
  shift
  set +e
  FM_TEST_DIR="$dir" PATH="$dir/fakebin:$PATH" "$CODE_REVIEW" "$@" > "$dir/out" 2> "$dir/err"
  RC=$?
  set -e
  OUT=$(cat "$dir/out")
  ERR=$(cat "$dir/err")
}

diff_id() {
  git patch-id --stable < "$1/diff" | awk '{ print $1 }'
}

test_classify_exempts_records_receipts_data_seed_and_markdown_only() {
  local dir path
  dir=$(make_case classify)
  for path in docs/records/2026/a.json docs/receipts/r.pdf data/x/y.csv seed/products.json README.md docs/guide.md; do
    run_case "$dir" classify "$path"
    [ "$OUT" = exempt ] || fail "classify: $path should be exempt, got '$OUT'"
  done
  for path in bin/tool.sh docs/recordsx/a.json src/data/x.py seed.sql README.md.sh .github/workflows/ci.yml docs/guide.html; do
    run_case "$dir" classify "$path"
    [ "$OUT" = code-changing ] || fail "classify: $path should be code-changing, got '$OUT'"
  done
  run_case "$dir" classify docs/records/a.json data/b README.md
  [ "$OUT" = exempt ] || fail "classify: an all-exempt set should be exempt, got '$OUT'"
  run_case "$dir" classify docs/records/a.json bin/tool.sh
  [ "$OUT" = code-changing ] || fail "classify: one code path should make the set code-changing, got '$OUT'"
  printf '%s\n' data/a '' seed/b | FM_TEST_DIR="$dir" "$CODE_REVIEW" classify > "$dir/out"
  [ "$(cat "$dir/out")" = exempt ] || fail "classify: stdin paths should classify the same way"
  pass "fm-code-review classify exempts only records, receipts, data, seed, and Markdown paths"
}

test_status_reads_exempt_unreviewed_and_reviewed() {
  local dir id
  dir=$(make_case status-exempt data/x.csv docs/records/a.json)
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "status-exempt: an exempt PR should exit 0"
  case "$OUT" in exempt:*) ;; *) fail "status-exempt: got '$OUT'" ;; esac
  assert_no_grep 'pr diff' "$dir/gh.log" "status-exempt: an exempt PR needs no diff read"

  dir=$(make_case status-rename docs/new-name.md)
  jq -c '.[0].previous_filename = "bin/old.sh"' "$dir/files.json" > "$dir/files.next" && mv "$dir/files.next" "$dir/files.json"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-rename: a rename out of code is code-changing"

  dir=$(make_case status-unreviewed bin/tool.sh)
  id=$(diff_id "$dir")
  jq -nc --arg b "<!-- fm-code-review v1 diff=$id head=$HEAD_SHA -->" \
    '[{author_association: "CONTRIBUTOR", body: $b}, {author_association: "OWNER", body: ("quoted " + $b)}]' \
    > "$dir/comments.json"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-unreviewed: an untrusted or inexact record must not count"
  [ "$OUT" = "unreviewed: diff $id of $URL changes code and carries no code review record for it" ] \
    || fail "status-unreviewed: got '$OUT'"

  jq -nc --arg b "note above
<!-- fm-code-review v1 diff=$id head=$HEAD_SHA -->
Code review done." '[{author_association: "MEMBER", body: $b}]' > "$dir/comments.json"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "status-reviewed: a member's record for this diff should count"
  [ "$OUT" = "reviewed: diff $id of $URL carries a code review record" ] || fail "status-reviewed: got '$OUT'"

  # A rebase moves line numbers and the index line but leaves the change alone.
  sed -e 's/^@@ -1,2 +1,2 @@$/@@ -40,2 +40,2 @@/' -e 's/^index .*/index 3333333..4444444 100755/' \
    "$dir/diff" > "$dir/diff.next" && mv "$dir/diff.next" "$dir/diff"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "status-rebased: a rebase that keeps the change should keep the record"
  sed 's/^+echo new$/+echo newer/' "$dir/diff" > "$dir/diff.next" && mv "$dir/diff.next" "$dir/diff"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-changed: a changed diff needs a new review"
  pass "fm-code-review status reads exempt, unreviewed, and reviewed by trusted record and diff"
}

test_status_refuses_unreadable_and_non_github() {
  local dir
  dir=$(make_case status-unreadable bin/tool.sh)
  : > "$dir/files-fail"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "status-unreadable: an unreadable file list should exit 2"
  assert_contains "$ERR" 'could not read the changed files' "status-unreadable: error did not say why"
  run_case "$dir" status https://gitlab.example/group/project/-/merge_requests/7
  expect_code 2 "$RC" "status-gitlab: a GitLab URL is not reviewable here"
  run_case "$dir" status
  expect_code 2 "$RC" "status-usage: a missing URL is a usage error"
  pass "fm-code-review status refuses unreadable PRs and non-GitHub URLs"
}

test_record_posts_once_for_the_current_diff() {
  local dir id
  dir=$(make_case record bin/tool.sh)
  id=$(diff_id "$dir")
  run_case "$dir" record "$URL" --note 'Review: two findings fixed, one answered.'
  expect_code 0 "$RC" "record: posting the record should succeed"
  [ "$OUT" = "reviewed: diff $id of $URL carries a code review record" ] || fail "record: got '$OUT'"
  jq -r '.[0].body' "$dir/comments.json" > "$dir/body"
  [ "$(sed -n 1p "$dir/body")" = "<!-- fm-code-review v1 diff=$id head=$HEAD_SHA -->" ] \
    || fail "record: marker line was $(sed -n 1p "$dir/body")"
  [ "$(sed -n 2p "$dir/body")" = 'Review: two findings fixed, one answered.' ] || fail "record: note was not the body"
  run_case "$dir" record "$URL"
  expect_code 0 "$RC" "record-again: an already reviewed diff should succeed"
  [ "$(grep -c '^pr comment' "$dir/gh.log")" -eq 1 ] || fail "record-again: a second record was posted"

  dir=$(make_case record-exempt seed/a.json)
  run_case "$dir" record "$URL"
  expect_code 0 "$RC" "record-exempt: an exempt PR needs no record"
  assert_no_grep 'pr comment' "$dir/gh.log" "record-exempt: a record was posted for an exempt PR"

  dir=$(make_case record-fails bin/tool.sh)
  : > "$dir/comment-fail"
  run_case "$dir" record "$URL"
  expect_code 1 "$RC" "record-fails: a failed post should exit 1"
  assert_contains "$ERR" 'could not post the code review record' "record-fails: error did not say why"
  pass "fm-code-review record posts one record for the current diff and reads it back"
}

test_classify_exempts_records_receipts_data_seed_and_markdown_only
test_status_reads_exempt_unreviewed_and_reviewed
test_status_refuses_unreadable_and_non_github
test_record_posts_once_for_the_current_diff

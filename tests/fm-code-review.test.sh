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

# A fixture directory holding the PR's files, diff, comments, head, and base
# branch, and a fake gh over it. The base branch keeps no risk-tiers.toml until
# a case writes one with write_table. `gh pr comment` appends an OWNER comment,
# as the authenticated repository owner's comment reads back. Args: name path...
make_case() {
  local name=$1 dir
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename: .})' > "$dir/files.json"
  printf '%s\n' '[]' > "$dir/comments.json"
  printf '%s\n' "$HEAD_SHA" > "$dir/head"
  printf '%s\n' '{"base": {"ref": "main"}}' > "$dir/pull.json"
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
  "api repos/example/repo/pulls/12") gh_jq "$FM_TEST_DIR/pull.json" "$@" ;;
  "api -H")
    case "$4" in
      "repos/example/repo/contents/risk-tiers.toml?ref=$(jq -r '.base.ref | @uri' "$FM_TEST_DIR/pull.json")") ;;
      *) exit 1 ;;
    esac
    if [ -f "$FM_TEST_DIR/table-fail" ]; then
      echo 'gh: Server Error (HTTP 502)' >&2
      exit 1
    fi
    if [ ! -f "$FM_TEST_DIR/risk-tiers.toml" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    cat "$FM_TEST_DIR/risk-tiers.toml"
    ;;
  "pr diff")
    case " $* " in
      *" --help "*)
        [ -f "$FM_TEST_DIR/old-gh" ] || printf '      --allow-escape-sequences   Output escape sequences\n'
        exit 0
        ;;
    esac
    if [ -f "$FM_TEST_DIR/old-gh" ]; then
      case " $* " in
        *" --allow-escape-sequences "*) printf 'unknown flag: --allow-escape-sequences\n' >&2; exit 1 ;;
      esac
    fi
    if [ -f "$FM_TEST_DIR/diff-escapes" ]; then
      case " $* " in
        *" --allow-escape-sequences "*) ;;
        *)
          printf 'the diff contains terminal escape sequences; pass --allow-escape-sequences to output it anyway\n' >&2
          exit 1
          ;;
      esac
    fi
    if [ -f "$FM_TEST_DIR/diff-fail" ]; then
      cat "$FM_TEST_DIR/diff-fail" >&2
      exit 1
    fi
    cat "$FM_TEST_DIR/diff"
    ;;
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
  git patch-id --verbatim < "$1/diff" | awk '{ print $1 }'
}

# A tier table like the fleet's: Thor and skill text are tinker, the gate is
# shared, and business code, seed and data are business by default. Args: dir
write_table() {
  cat > "$1/risk-tiers.toml" <<'TOML'
default = "business"
ignore = ["docs/**", "*.md"]
max_tinker_lines = 400

[[tinker]]
host = "thor"
paths = ["hosts/thor/**", ".agents/skills/**"]
checks = ["checks/thor-evaluation.sh"]
readback = "brew list --cask <name> on Thor"

[[shared]]
paths = ["check.sh", "hooks/**", "hosts/*/agent-guidance.md"]

[[business]]
paths = ["src/business/**", "seed/**"]
TOML
}

# Sets each listed file's changed-line count. Args: dir count
set_changes() {
  jq -c --argjson n "$2" 'map(.changes = $n)' "$1/files.json" > "$1/files.next" && mv "$1/files.next" "$1/files.json"
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
  pass "fm-code-review classify without a table exempts only records, receipts, data, seed, and Markdown paths"
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
  sed 's/^+echo new$/+  echo new/' "$dir/diff" > "$dir/diff.next" && mv "$dir/diff.next" "$dir/diff"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-reindented: an indentation-only change needs a new review"
  sed 's/^+  echo new$/+echo newer/' "$dir/diff" > "$dir/diff.next" && mv "$dir/diff.next" "$dir/diff"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-changed: a changed diff needs a new review"

  # A record whose comment GitHub stored with CRLF line endings still counts.
  id=$(diff_id "$dir")
  jq -nc --arg b "$(printf '<!-- fm-code-review v1 diff=%s head=%s -->\r\nReviewed.\r' "$id" "$HEAD_SHA")" \
    '[{author_association: "OWNER", body: $b}]' > "$dir/comments.json"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "status-crlf: a CRLF record should count"
  pass "fm-code-review status reads exempt, unreviewed, and reviewed by trusted record and diff"
}

test_status_handles_github_limits() {
  local dir
  # GitHub will not serve a very large PR's diff, so the head commit keys it,
  # while any other failed diff read leaves the state unreadable.
  dir=$(make_case status-no-diff bin/tool.sh)
  printf 'could not find pull request diff: HTTP 401: Bad credentials\n' > "$dir/diff-fail"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "status-diff-error: a transient diff failure must read as unreadable"
  printf 'could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of files (300).\n' > "$dir/diff-fail"
  jq -nc --arg b "<!-- fm-code-review v1 diff=$HEAD_SHA head=$HEAD_SHA -->" \
    '[{author_association: "OWNER", body: $b}]' > "$dir/comments.json"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "status-no-diff: a head-keyed record should count when the diff is unavailable"
  printf '%s\n' 9999999999999999999999999999999999999999 > "$dir/head"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-no-diff: a new head needs a new review when the diff is unavailable"

  # gh refuses a diff holding terminal escape sequences unless told to print
  # it; the fingerprint must still come from that diff, not read unreadable.
  dir=$(make_case status-escapes bin/tool.sh)
  : > "$dir/diff-escapes"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-escapes: a diff with escape sequences must still be fingerprinted"
  assert_contains "$(cat "$dir/gh.log")" "--allow-escape-sequences" "status-escapes: the diff was not read with the flag"
  run_case "$dir" record "$URL"
  expect_code 0 "$RC" "status-escapes: a diff with escape sequences must still be recordable"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "status-escapes: the recorded diff must then read reviewed"

  # A gh too old to know the flag is never passed it.
  dir=$(make_case status-old-gh bin/tool.sh)
  : > "$dir/old-gh"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-old-gh: an older gh must still fingerprint an ordinary diff"

  # GitHub lists at most 3000 files, so the unlisted rest may be code.
  dir=$(make_case status-file-cap)
  seq 1 3000 | sed 's|^|docs/records/r|' | jq -R . | jq -sc 'map({filename: .})' > "$dir/files.json"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "status-file-cap: a PR at the file-list cap must count as code-changing"
  pass "fm-code-review status keys an unservable diff by head, reads a diff gh calls unsafe to print on any gh, and treats the file-list cap as code"
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

test_classify_with_a_table_exempts_only_tinker_and_ignored_paths() {
  local dir path
  dir=$(make_case classify-table)
  write_table "$dir"
  for path in hosts/thor/homebrew.nix .agents/skills/x/SKILL.md README.md docs/guide.md; do
    run_case "$dir" classify --table "$dir/risk-tiers.toml" "$path"
    [ "$OUT" = exempt ] || fail "classify-table: $path should be exempt, got '$OUT'"
  done
  # Business seed and data files and records are reviewed once a table decides.
  for path in check.sh hooks/pre-push seed/products.json data/x/y.csv docs.sh hosts/thor/agent-guidance.md src/business/price.py; do
    run_case "$dir" classify --table "$dir/risk-tiers.toml" "$path"
    [ "$OUT" = code-changing ] || fail "classify-table: $path should be code-changing, got '$OUT'"
  done
  run_case "$dir" classify --table "$dir/risk-tiers.toml" hosts/thor/a.nix seed/b.json
  [ "$OUT" = code-changing ] || fail "classify-table: one business path should make the set code-changing, got '$OUT'"
  run_case "$dir" classify seed/products.json
  [ "$OUT" = exempt ] || fail "classify-table: without --table seed/ should stay exempt, got '$OUT'"

  printf 'default = "tinker"\n[[shared]]\npaths = ["bin/**"]\n' > "$dir/bad.toml"
  run_case "$dir" classify --table "$dir/bad.toml" bin/x
  expect_code 2 "$RC" "classify-table: a default below a named tier must be refused"
  assert_contains "$ERR" 'not the highest tier' "classify-table: the bad default was not named"
  printf 'default = "shared"\n[[tinker]]\nhost = "thor"\n' > "$dir/bad.toml"
  run_case "$dir" classify --table "$dir/bad.toml" bin/x
  expect_code 2 "$RC" "classify-table: a rule without paths must be refused"
  printf 'default = \n' > "$dir/bad.toml"
  run_case "$dir" classify --table "$dir/bad.toml" bin/x
  expect_code 2 "$RC" "classify-table: a table that does not parse must be refused"
  pass "fm-code-review classify --table exempts only tinker and ignored paths and refuses a bad table"
}

test_status_with_a_table_reviews_shared_and_business_but_not_tinker() {
  local dir id
  dir=$(make_case table-tinker hosts/thor/homebrew.nix docs/thor.md)
  write_table "$dir"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "table-tinker: a tinker PR should be exempt"
  [ "$OUT" = "exempt: $URL is tinker under its base branch's risk-tiers.toml: every changed path it counts is tinker" ] \
    || fail "table-tinker: got '$OUT'"
  assert_no_grep 'pr diff' "$dir/gh.log" "table-tinker: a tinker PR needs no diff read"

  dir=$(make_case table-ignored docs/a.md NOTES.md)
  write_table "$dir"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "table-ignored: a PR of only ignored paths should be exempt"
  assert_contains "$OUT" 'only paths the table ignores' "table-ignored: got '$OUT'"

  dir=$(make_case table-tinker-large hosts/thor/a.nix hosts/thor/b.nix)
  write_table "$dir"
  set_changes "$dir" 201
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "table-tinker-large: a tinker PR past max_tinker_lines takes the default"
  assert_contains "$OUT" 'is business under' "table-tinker-large: got '$OUT'"
  assert_contains "$OUT" '402 changed lines pass max_tinker_lines (400)' "table-tinker-large: got '$OUT'"
  set_changes "$dir" 200
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "table-tinker-at-limit: a tinker PR at max_tinker_lines stays tinker"

  dir=$(make_case table-shared hooks/pre-push hosts/thor/a.nix)
  write_table "$dir"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "table-shared: a shared PR needs a review"
  id=$(diff_id "$dir")
  [ "$OUT" = "unreviewed: diff $id of $URL is shared under its base branch's risk-tiers.toml (hooks/pre-push is shared) and carries no code review record for it" ] \
    || fail "table-shared: got '$OUT'"
  run_case "$dir" record "$URL"
  expect_code 0 "$RC" "table-shared: recording the review should succeed"
  [ "$OUT" = "reviewed: diff $id of $URL carries a code review record" ] || fail "table-shared: record read back '$OUT'"

  # Seed and data are exempt without a table and reviewed under one.
  dir=$(make_case table-business seed/ads.json data/feed.csv)
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "no-table-business: seed and data stay exempt without a table"
  write_table "$dir"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "table-business: seed and data need a review under a table"
  assert_contains "$OUT" 'is business under' "table-business: got '$OUT'"

  # A rename out of a business path is business; a change to the table itself
  # matches no rule, so it takes the default.
  dir=$(make_case table-rename hosts/thor/moved.nix)
  write_table "$dir"
  jq -c '.[0].previous_filename = "src/business/moved.nix"' "$dir/files.json" > "$dir/files.next" && mv "$dir/files.next" "$dir/files.json"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "table-rename: a rename out of business is business"
  dir=$(make_case table-self risk-tiers.toml)
  write_table "$dir"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "table-self: a change to the table takes its default"
  assert_contains "$OUT" 'risk-tiers.toml matches no rule (default business)' "table-self: got '$OUT'"
  pass "fm-code-review status reviews shared and business PRs and exempts tinker ones under a table"
}

test_status_reads_the_table_from_the_base_branch() {
  local dir
  dir=$(make_case table-base hosts/thor/a.nix)
  write_table "$dir"
  printf '%s\n' '{"base": {"ref": "release/2026 q4"}}' > "$dir/pull.json"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "table-base: the table should be read from the PR's base branch"
  assert_grep 'contents/risk-tiers.toml?ref=release%2F2026%20q4' "$dir/gh.log" "table-base: the base branch was not the ref read"

  : > "$dir/table-fail"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-unreadable: a failed table read other than not-found must be unreadable"
  assert_contains "$ERR" "could not read the risk-tiers.toml" "table-unreadable: error did not say why"
  rm -f "$dir/table-fail"

  printf 'default = "tinker"\n[[business]]\npaths = ["src/**"]\n' > "$dir/risk-tiers.toml"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-invalid: an invalid base table must leave the state unreadable"
  printf '%s\n' '{"base": {"ref": ""}}' > "$dir/pull.json"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-no-base: an unreadable base branch must leave the state unreadable"
  pass "fm-code-review status reads the base branch's table and fails closed when it cannot"
}

test_classify_exempts_records_receipts_data_seed_and_markdown_only
test_classify_with_a_table_exempts_only_tinker_and_ignored_paths
test_status_with_a_table_reviews_shared_and_business_but_not_tinker
test_status_reads_the_table_from_the_base_branch
test_status_reads_exempt_unreviewed_and_reviewed
test_status_handles_github_limits
test_status_refuses_unreadable_and_non_github
test_record_posts_once_for_the_current_diff

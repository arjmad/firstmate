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
# fake gh over it. Main keeps no risk-tiers.toml until a case builds a remote
# with make_remote. `gh pr comment` appends an OWNER comment, as the
# authenticated repository owner's comment reads back. Args: name path...
make_case() {
  local name=$1 dir
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename: .})' > "$dir/files.json"
  printf '%s\n' '[]' > "$dir/comments.json"
  printf '%s\n' "$HEAD_SHA" > "$dir/head"
  mkdir -p "$dir/tmp"
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
  "api repos/example/repo/contents/risk-tiers.toml?ref=main")
    if [ -f "$FM_TEST_DIR/table-fail" ]; then
      echo 'gh: Server Error (HTTP 502)' >&2
      exit 1
    fi
    if ! git --git-dir="$FM_TEST_DIR/remote.git" cat-file -e main:risk-tiers.toml 2>/dev/null; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    printf 'file\n'
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
  "api repos/example/repo/compare/"*)
    [ -f "$FM_TEST_DIR/compare.json" ] || exit 1
    gh_jq "$FM_TEST_DIR/compare.json" "$@"
    ;;
  "pr view")
    # A heads file, one head per line, is read one line per call: a push
    # landing between two reads.
    if [ -s "$FM_TEST_DIR/heads" ]; then
      sed -n 1p "$FM_TEST_DIR/heads"
      sed 1d "$FM_TEST_DIR/heads" > "$FM_TEST_DIR/heads.next" && mv "$FM_TEST_DIR/heads.next" "$FM_TEST_DIR/heads"
    else
      cat "$FM_TEST_DIR/head"
    fi
    ;;
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
  FM_TEST_DIR="$dir" PATH="$dir/fakebin:$PATH" TMPDIR="$dir/tmp" \
    FM_RISK_TIER="${FM_TEST_CLASSIFIER:-$dir/fakebin/risk-tier}" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$dir/remote.git.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/example/repo.git \
    "$CODE_REVIEW" "$@" > "$dir/out" 2> "$dir/err"
  RC=$?
  set -e
  OUT=$(cat "$dir/out")
  ERR=$(cat "$dir/err")
}

diff_id() {
  git patch-id --verbatim < "$1/diff" | awk '{ print $1 }'
}

# The repository the classifier's clone fetches: main holds the table at
# $dir/table.toml and bin/tool.sh, and refs/pull/12/head adds one commit that
# writes each listed path. A stub classifier stands in for the fleet's
# risk-tier: it checks the clone it was handed and prints $dir/tier. Args: dir
# path...
make_remote() {
  local dir=$1 work path
  shift
  work="$dir/remote-work"
  git init -q --bare "$dir/remote.git"
  git -C "$dir/remote.git" config uploadpack.allowFilter true
  git init -q -b main "$work"
  mkdir -p "$work/bin"
  printf 'echo old\n' > "$work/bin/tool.sh"
  cp "$dir/table.toml" "$work/risk-tiers.toml"
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.com commit -q -m main
  for path in "$@"; do
    mkdir -p "$work/$(dirname "$path")"
    printf 'changed\n' >> "$work/$path"
  done
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.com commit -q -m change
  git -C "$work" push -q "$dir/remote.git" HEAD~1:refs/heads/main HEAD:refs/pull/12/head
  git -C "$work" rev-parse HEAD > "$dir/pr-head"
  cp "$dir/pr-head" "$dir/head"
  cat > "$dir/fakebin/risk-tier" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_DIR/classifier.log"
[ "$1 $3" = "--root --head" ] && [ "$#" -eq 4 ] || { echo "stub: usage" >&2; exit 2; }
cmp -s "$2/risk-tiers.toml" "$FM_TEST_DIR/table.toml" || { echo "stub: main's table is not in the tree" >&2; exit 2; }
git -C "$2" rev-parse -q --verify origin/main > /dev/null || { echo "stub: no origin/main" >&2; exit 2; }
[ "$4" = "$(cat "$FM_TEST_DIR/pr-head")" ] || { echo "stub: not the PR head" >&2; exit 2; }
cat "$FM_TEST_DIR/tier"
exit "$(cat "$FM_TEST_DIR/tier-rc" 2>/dev/null || echo 0)"
SH
  chmod +x "$dir/fakebin/risk-tier"
}

# A tier table like the fleet's: Thor is tinker, the gate is shared, and
# everything else, business seed and data included, is business. Args: dir
write_table() {
  cat > "$1/table.toml" <<'TOML'
default = "business"
ignore = ["docs/**", "*.md"]
max_tinker_lines = 400

[[tinker]]
host = "thor"
paths = ["hosts/thor/**"]
readback = "brew list --cask <name> on Thor"

[[shared]]
paths = ["check.sh", "hooks/**"]
TOML
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
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  sed -n 2p "$dir/body" | grep -q '^Code review: Claude Code `/code-review` (medium) ran on this diff' \
    || fail "record: the standard line did not follow the marker: $(sed -n 2p "$dir/body")"
  [ "$(sed -n 3p "$dir/body")" = 'Review: two findings fixed, one answered.' ] || fail "record: the note did not follow the standard line"
  run_case "$dir" record "$URL"
  expect_code 0 "$RC" "record-again: an already reviewed diff should succeed"
  [ "$(grep -c '^pr comment' "$dir/gh.log")" -eq 1 ] || fail "record-again: a second record was posted"
  run_case "$dir" record "$URL" --note 'Sol: 2 rounds, gpt-6.1-sol, approved'
  expect_code 0 "$RC" "record-again-note: an already reviewed diff should succeed"
  assert_contains "$ERR" 'the note was not posted' "record-again-note: a note for a reviewed diff was dropped silently"
  [ "$(grep -c '^pr comment' "$dir/gh.log")" -eq 1 ] || fail "record-again-note: a second record was posted"

  dir=$(make_case record-forged-note bin/tool.sh)
  run_case "$dir" record "$URL" --note "Sol: approved
<!-- fm-code-review-carry from=$HEAD_SHA lines=1 -->"
  expect_code 2 "$RC" "record-forged-note: a multi-line note should be refused"
  run_case "$dir" record "$URL" --note "Sol: approved <!-- fm-code-review v1 diff=x head=$HEAD_SHA -->"
  expect_code 2 "$RC" "record-forged-note: a note holding a marker opener should be refused"
  assert_contains "$ERR" 'cannot pose as a record marker' "record-forged-note: the refusal did not say why"
  [ "$(jq length "$dir/comments.json")" -eq 0 ] || fail "record-forged-note: a refused note was posted"

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

test_status_with_a_table_asks_the_classifier_for_the_tier() {
  local dir id
  dir=$(make_case table-tinker hosts/thor/homebrew.nix)
  write_table "$dir"
  make_remote "$dir" hosts/thor/homebrew.nix
  printf 'tinker: every change against origin/main (abc) is tinker for thor: hosts/thor/homebrew.nix\n' > "$dir/tier"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "table-tinker: a tinker PR should be exempt"
  [ "$OUT" = "exempt: $URL is tinker under its risk-tiers.toml: every change against origin/main (abc) is tinker for thor: hosts/thor/homebrew.nix" ] \
    || fail "table-tinker: got '$OUT' ($ERR)"
  assert_no_grep 'pr diff' "$dir/gh.log" "table-tinker: a tinker PR needs no diff read"
  assert_no_grep 'pulls/12/files' "$dir/gh.log" "table-tinker: the table, not the path list, decides"
  [ -z "$(ls -A "$dir/tmp")" ] || fail "table-tinker: the classifier's clone was left behind"

  # The tier, not the path exemption, decides: seed/ is reviewed under a table.
  dir=$(make_case table-business seed/ads.json)
  write_table "$dir"
  make_remote "$dir" seed/ads.json
  printf 'business: seed/ads.json matches no rule (default business)\n' > "$dir/tier"
  run_case "$dir" status "$URL"
  expect_code 1 "$RC" "table-business: a business PR needs a review"
  id=$(diff_id "$dir")
  [ "$OUT" = "unreviewed: diff $id of $URL is business under its risk-tiers.toml (seed/ads.json matches no rule (default business)) and carries no code review record for it" ] \
    || fail "table-business: got '$OUT' ($ERR)"

  dir=$(make_case table-shared hooks/pre-push)
  write_table "$dir"
  make_remote "$dir" hooks/pre-push
  printf 'shared: hooks/pre-push is shared (check.sh, hooks/**)\n' > "$dir/tier"
  run_case "$dir" record "$URL"
  expect_code 0 "$RC" "table-shared: recording a shared PR's review should succeed"
  assert_contains "$OUT" 'reviewed: diff' "table-shared: record read back '$OUT'"
  [ "$(wc -l < "$dir/classifier.log")" -eq 1 ] || fail "table-shared: the classifier ran more than once in one record"
  pass "fm-code-review status takes a tabled repository's tier from its classifier: tinker exempt, others reviewed"
}

test_status_with_a_table_fails_closed() {
  local dir
  dir=$(make_case table-refused hosts/thor/a.nix)
  write_table "$dir"
  make_remote "$dir" hosts/thor/a.nix
  printf '' > "$dir/tier"
  printf '2\n' > "$dir/tier-rc"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-refused: a classifier that refuses the table must leave the state unreadable"

  printf 'tinker: printed before a failure\n' > "$dir/tier"
  printf '1\n' > "$dir/tier-rc"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-failed-tier: a classifier that fails after printing a tier must leave the state unreadable"

  printf 'fast: whatever\n' > "$dir/tier"
  printf '0\n' > "$dir/tier-rc"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-garbled: a line that names no tier must leave the state unreadable"
  assert_contains "$ERR" 'printed no tier' "table-garbled: error did not say why"

  printf 'tinker: fine\n' > "$dir/tier"
  FM_TEST_CLASSIFIER="$dir/no-such-risk-tier" run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-no-classifier: a missing classifier must leave the state unreadable"
  assert_contains "$ERR" 'no-such-risk-tier is not an executable file' "table-no-classifier: error did not name it"

  # GitHub can serve a new head before its pull request ref moves to it.
  printf '%s\n' 9999999999999999999999999999999999999999 > "$dir/head"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-ref-lags: a pull request ref behind the head must not be classified"
  assert_contains "$ERR" 'not its head 9999999999999999999999999999999999999999 yet' "table-ref-lags: error did not say why"
  cp "$dir/pr-head" "$dir/head"

  git --git-dir="$dir/remote.git" update-ref -d refs/pull/12/head
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-no-head: an unfetchable PR head must leave the state unreadable"
  assert_contains "$ERR" 'could not fetch main and the head' "table-no-head: error did not say why"

  : > "$dir/table-fail"
  run_case "$dir" status "$URL"
  expect_code 2 "$RC" "table-unknown: an unreadable table check must leave the state unreadable"
  assert_contains "$ERR" 'keeps a risk-tiers.toml on main' "table-unknown: error did not say why"
  [ -z "$(ls -A "$dir/tmp")" ] || fail "table-refused: a classifier clone was left behind"
  pass "fm-code-review status fails closed when a tabled repository's tier cannot be read"
}

# The fleet's own classifier, when this host has it (FM_TEST_RISK_TIER, or
# FLEET_NIX's bin/risk-tier), on the cases the stub cannot speak for.
test_status_with_the_fleet_classifier() {
  local classifier=${FM_TEST_RISK_TIER:-${FLEET_NIX:-$HOME/nix}/bin/risk-tier} dir
  if [ ! -x "$classifier" ]; then
    echo "skip: no fleet risk-tier classifier at $classifier (set FM_TEST_RISK_TIER)"
    return 0
  fi
  dir=$(make_case real-tinker hosts/thor/homebrew.nix docs/thor.md)
  write_table "$dir"
  make_remote "$dir" hosts/thor/homebrew.nix docs/thor.md
  FM_TEST_CLASSIFIER=$classifier run_case "$dir" status "$URL"
  expect_code 0 "$RC" "real-tinker: a Thor-only PR should be exempt ($ERR)"
  assert_contains "$OUT" 'is tinker under its risk-tiers.toml' "real-tinker: got '$OUT'"

  dir=$(make_case real-seed seed/ads.json)
  write_table "$dir"
  make_remote "$dir" seed/ads.json
  FM_TEST_CLASSIFIER=$classifier run_case "$dir" status "$URL"
  expect_code 1 "$RC" "real-seed: a seed/ PR should need a review ($ERR)"
  assert_contains "$OUT" 'is business under' "real-seed: got '$OUT'"

  # A PR that rewrites the table to make itself tinker is still the default.
  dir=$(make_case real-self risk-tiers.toml hosts/thor/a.nix)
  write_table "$dir"
  make_remote "$dir" hosts/thor/a.nix
  printf '[[tinker]]\npaths = ["**"]\nreadback = "none"\n' > "$dir/remote-work/extra.toml"
  (cd "$dir/remote-work" && git checkout -q HEAD -- . && sed -i.bak '/^\[\[shared\]\]/,$d' risk-tiers.toml \
    && rm -f risk-tiers.toml.bak && cat extra.toml >> risk-tiers.toml && rm extra.toml \
    && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m lower \
    && git push -q -f "$dir/remote.git" HEAD:refs/pull/12/head && git rev-parse HEAD > "$dir/head")
  FM_TEST_CLASSIFIER=$classifier run_case "$dir" status "$URL"
  expect_code 1 "$RC" "real-self: a PR that lowers its own table must need a review ($ERR)"
  assert_contains "$OUT" 'risk-tiers.toml itself changed' "real-self: got '$OUT'"

  dir=$(make_case real-docs docs/guide.md)
  write_table "$dir"
  make_remote "$dir" docs/guide.md
  FM_TEST_CLASSIFIER=$classifier run_case "$dir" status "$URL"
  expect_code 1 "$RC" "real-docs: a PR of only ignored paths takes the default and needs a review ($ERR)"
  pass "fm-code-review status with the fleet classifier: Thor exempt, seed reviewed, a self-lowering table reviewed"
}

# A trusted full record for an earlier diff at <head>, plus optional extra
# comment bodies. Args: dir head [body...]
REVIEWED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_DIFF=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
full_record() {
  local dir=$1 head=$2
  shift 2
  jq -c --arg b "<!-- fm-code-review v1 diff=$OLD_DIFF head=$head -->
Code review: ran." '. + [{author_association: "OWNER", body: $b}]' "$dir/comments.json" > "$dir/comments.next"
  mv "$dir/comments.next" "$dir/comments.json"
}

# The compare between the reviewed head and the PR head: status, then one
# "path changes [none]" argument per file ("none" means no text patch).
# Args: dir status file...
write_compare() {
  local dir=$1 status=$2 spec
  shift 2
  for spec in "$@"; do printf '%s\n' "$spec"; done \
    | jq -R 'split(" ") | {filename: .[0], changes: (.[1] | tonumber)} + (if .[2] == "none" then {} else {patch: "@@"} end)' \
    | jq -sc --arg s "$status" '{status: $s, files: .}' > "$dir/compare.json"
}

test_record_carry_covers_a_small_follow_up() {
  local dir id
  dir=$(make_case carry-small bin/tool.sh)
  id=$(diff_id "$dir")
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'bin/tool.sh 4' 'tests/tool.test.sh 6' 'docs/guide.md 80'
  run_case "$dir" record "$URL" --carry --note 'Sol: 1 round, gpt-6.1-sol, approved'
  expect_code 0 "$RC" "carry-small: ten changed lines outside exempt paths should carry"
  [ "$OUT" = "reviewed: diff $id of $URL carries a code review record" ] || fail "carry-small: got '$OUT'"
  assert_grep "api repos/example/repo/compare/$REVIEWED_HEAD...$HEAD_SHA" "$dir/gh.log" "carry-small: did not compare the reviewed head with the PR head"
  jq -r '.[-1].body' "$dir/comments.json" > "$dir/body"
  [ "$(sed -n 1p "$dir/body")" = "<!-- fm-code-review v1 diff=$id head=$HEAD_SHA -->" ] || fail "carry-small: marker line was $(sed -n 1p "$dir/body")"
  [ "$(sed -n 2p "$dir/body")" = "<!-- fm-code-review-carry from=$REVIEWED_HEAD lines=10 -->" ] || fail "carry-small: carry line was $(sed -n 2p "$dir/body")"
  sed -n 3p "$dir/body" | grep -q "^Code review carried from the full review recorded at $REVIEWED_HEAD" \
    || fail "carry-small: the carry's standard line was $(sed -n 3p "$dir/body")"
  [ "$(sed -n 4p "$dir/body")" = 'Sol: 1 round, gpt-6.1-sol, approved' ] || fail "carry-small: the note did not follow the carry's standard line"
  run_case "$dir" status "$URL"
  expect_code 0 "$RC" "carry-small: a carried record must read as reviewed"

  dir=$(make_case carry-exempt bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'docs/fork-decisions.md 400' 'data/x.csv 900'
  run_case "$dir" record "$URL" --carry
  expect_code 0 "$RC" "carry-exempt: an exempt-only follow-up of any size should carry"
  pass "fm-code-review record --carry carries the last full review over a small or exempt-only follow-up"
}

test_record_carry_refuses_what_it_cannot_cover() {
  local dir
  dir=$(make_case carry-none bin/tool.sh)
  write_compare "$dir" ahead 'bin/tool.sh 1'
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-none: a PR with no full record has nothing to carry"
  assert_contains "$ERR" 'no full code review record to carry' "carry-none: error did not say why"

  dir=$(make_case carry-large bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'bin/tool.sh 6' 'bin/other.sh 5' 'README.md 50'
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-large: eleven changed lines outside exempt paths must not carry"
  assert_contains "$ERR" 'changes 11 counted lines, more than the carry cap of 10' "carry-large: error did not name the count and cap"

  dir=$(make_case carry-rebased bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" diverged 'bin/tool.sh 1'
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-rebased: a head that does not descend from the reviewed head must not carry"
  assert_contains "$ERR" 'does not descend from the reviewed head' "carry-rebased: error did not say why"

  dir=$(make_case carry-identical bin/tool.sh)
  full_record "$dir" "$HEAD_SHA"
  write_compare "$dir" identical
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-identical: a changed diff at the reviewed head (the base moved) must not carry"
  assert_contains "$ERR" 'its diff changed only because the base moved' "carry-identical: error did not say why"

  dir=$(make_case carry-rename-in bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'bin/helper.sh 1'
  jq -c '.files[0].previous_filename = "notes/helper.md"' "$dir/compare.json" > "$dir/compare.next" && mv "$dir/compare.next" "$dir/compare.json"
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-rename-in: a file renamed from an exempt path into code must not carry"
  assert_contains "$ERR" 'whole content is new to review' "carry-rename-in: error did not say why"

  dir=$(make_case carry-moved bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'bin/tool.sh 1'
  printf '%s\n' "$HEAD_SHA" "$HEAD_SHA" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee > "$dir/heads"
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-moved: a head that moves while the carry is measured must not carry"
  assert_contains "$ERR" 'moved while the carry was measured' "carry-moved: error did not say why"

  dir=$(make_case carry-binary bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'bin/logo.png 0 none'
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-binary: a non-exempt change without a text patch must not carry"

  dir=$(make_case carry-renamed bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'docs/tool.md 1'
  jq -c '.files[0].previous_filename = "bin/tool.sh"' "$dir/compare.json" > "$dir/compare.next" && mv "$dir/compare.next" "$dir/compare.json"
  run_case "$dir" record "$URL" --carry
  expect_code 0 "$RC" "carry-renamed: a one-line rename out of code should count its old name and carry under the cap"
  assert_contains "$(jq -r '.[-1].body' "$dir/comments.json")" 'lines=1 -->' "carry-renamed: the rename's lines were not counted"

  dir=$(make_case carry-unreadable bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  run_case "$dir" record "$URL" --carry
  expect_code 2 "$RC" "carry-unreadable: a compare that cannot be read should exit 2"

  for dir in "$TMP_ROOT"/carry-none "$TMP_ROOT"/carry-large "$TMP_ROOT"/carry-rebased "$TMP_ROOT"/carry-identical \
    "$TMP_ROOT"/carry-rename-in "$TMP_ROOT"/carry-moved "$TMP_ROOT"/carry-binary "$TMP_ROOT"/carry-unreadable; do
    assert_no_grep 'pr comment' "$dir/gh.log" "$(basename "$dir"): a refused carry posted a record"
  done
  pass "fm-code-review record --carry refuses no full record, the cap, a rebase, an unchanged head, a rename into code, a moving head, an unmeasurable file, and an unreadable compare"
}

# Under a risk-tiers.toml only the table exempts a path, so a carry counts
# Markdown and data lines too.
test_record_carry_counts_every_path_under_a_table() {
  local dir
  dir=$(make_case carry-table seed/ads.json)
  write_table "$dir"
  make_remote "$dir" seed/ads.json
  printf 'business: seed/ads.json matches no rule (default business)\n' > "$dir/tier"
  full_record "$dir" "$REVIEWED_HEAD"
  write_compare "$dir" ahead 'AGENTS.md 400'
  run_case "$dir" record "$URL" --carry
  expect_code 1 "$RC" "carry-table: a large Markdown follow-up under a table must not carry"
  assert_contains "$ERR" 'changes 400 counted lines' "carry-table: the Markdown lines were not counted"
  write_compare "$dir" ahead 'AGENTS.md 3'
  run_case "$dir" record "$URL" --carry
  expect_code 0 "$RC" "carry-table: a small follow-up under a table should carry"
  pass "fm-code-review record --carry counts every path where a risk-tiers.toml decides"
}

# A carry measures from the last full review, never from an earlier carry, so
# a chain of small carries cannot add up past the cap unreviewed.
test_record_carry_measures_from_the_last_full_review() {
  local dir carried=cccccccccccccccccccccccccccccccccccccccc
  dir=$(make_case carry-chain bin/tool.sh)
  full_record "$dir" "$REVIEWED_HEAD"
  jq -c --arg b "<!-- fm-code-review v1 diff=$OLD_DIFF head=$carried -->
<!-- fm-code-review-carry from=$REVIEWED_HEAD lines=9 -->
Carried." '. + [{author_association: "OWNER", body: $b}]' "$dir/comments.json" > "$dir/comments.next"
  mv "$dir/comments.next" "$dir/comments.json"
  jq -c '. + [{author_association: "NONE", body: "<!-- fm-code-review v1 diff=\($d) head=\($h) -->"}]' \
    --arg d "$OLD_DIFF" --arg h dddddddddddddddddddddddddddddddddddddddd "$dir/comments.json" > "$dir/comments.next"
  mv "$dir/comments.next" "$dir/comments.json"
  write_compare "$dir" ahead 'bin/tool.sh 3'
  run_case "$dir" record "$URL" --carry
  expect_code 0 "$RC" "carry-chain: the follow-up within the cap should carry"
  assert_grep "api repos/example/repo/compare/$REVIEWED_HEAD...$HEAD_SHA" "$dir/gh.log" "carry-chain: did not measure from the last full review"
  assert_no_grep "compare/$carried" "$dir/gh.log" "carry-chain: measured from an earlier carry"
  assert_no_grep "compare/dddd" "$dir/gh.log" "carry-chain: measured from an untrusted author's record"
  pass "fm-code-review record --carry measures from the last trusted full review, not an earlier carry"
}

test_classify_exempts_records_receipts_data_seed_and_markdown_only
test_status_with_a_table_asks_the_classifier_for_the_tier
test_status_with_a_table_fails_closed
test_status_with_the_fleet_classifier
test_status_reads_exempt_unreviewed_and_reviewed
test_status_handles_github_limits
test_status_refuses_unreadable_and_non_github
test_record_posts_once_for_the_current_diff
test_record_carry_covers_a_small_follow_up
test_record_carry_refuses_what_it_cannot_cover
test_record_carry_measures_from_the_last_full_review
test_record_carry_counts_every_path_under_a_table

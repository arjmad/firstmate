#!/usr/bin/env bash
# Tests for bin/fm-pr-close.sh: it closes an open GitHub pull request and
# deletes its head branch only when the branch is firstmate's own, in the base
# repository, and still at the pull request's head; every other case closes the
# pull request (when open) and keeps the branch. Driven through the public
# entrypoint against a fake gh that logs every call and a real bare repository
# standing in for GitHub, so the leased delete is git's own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOSE="$ROOT/bin/fm-pr-close.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-close-tests)
URL=https://github.com/example/repo/pull/12

# A case directory with a fake gh and a bare remote.git whose branch
# fm/task-x1 is at the pull request's head (<tip> head) or one commit past it
# (<tip> beyond). The pull request reads as <state>, from a fork when <cross>
# is true, authored by <author>; the signed-in account is firstmate-bot.
# Args: name state cross author tip
make_case() {
  local dir="$TMP_ROOT/$1" work head
  mkdir -p "$dir/fakebin" "$dir/tmp"
  git init -q --bare "$dir/remote.git"
  work="$dir/work"
  git init -q -b main "$work"
  git -C "$work" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m head
  head=$(git -C "$work" rev-parse HEAD)
  [ "$5" = head ] || git -C "$work" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "pushed after the head was read"
  git -C "$work" push -q "$dir/remote.git" HEAD:refs/heads/fm/task-x1
  printf '%s\n' "$head" > "$dir/head"
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" fm/task-x1 "$head" "$3" "$4" > "$dir/view"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_DIR/gh.log"
case "$1 $2" in
  "pr view") cat "$FM_TEST_DIR/view" ;;
  "pr close") : ;;
  "api --hostname")
    [ "$3 $4" = "github.com user" ] || exit 1
    echo firstmate-bot
    ;;
  "auth git-credential") : ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

run_close() {
  local dir=$1
  shift
  set +e
  OUT=$(FM_TEST_DIR="$dir" PATH="$dir/fakebin:$PATH" TMPDIR="$dir/tmp" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$dir/remote.git.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/example/repo.git \
    "$CLOSE" "$@" 2> "$dir/err")
  RC=$?
  set -e
}

deleted() {
  ! git --git-dir="$1/remote.git" show-ref --verify --quiet refs/heads/fm/task-x1
}

test_own_branch_at_head_is_deleted() {
  local dir
  dir=$(make_case own OPEN false firstmate-bot head)
  run_close "$dir" "$URL" --comment "superseded"
  expect_code 0 "$RC" "own: the close should succeed: $(cat "$dir/err")"
  assert_contains "$OUT" "closed: $URL" "own: no closed line"
  assert_contains "$OUT" "deleted: branch fm/task-x1 of example/repo" "own: no deleted line: $OUT"
  grep -q '^pr close https://github.com/example/repo/pull/12 --comment superseded$' "$dir/gh.log" \
    || fail "own: the pull request was not closed with its comment: $(cat "$dir/gh.log")"
  deleted "$dir" || fail "own: the head branch was not deleted"
  ! grep -q -- '--delete-branch' "$dir/gh.log" || fail "own: gh's --delete-branch, which also deletes the local branch, was used"
  [ -z "$(ls -A "$dir/tmp")" ] || fail "own: the scratch repository was left behind"
  pass "fm-pr-close closes the pull request and deletes firstmate's own head branch at its head"
}

test_refusals_close_but_keep_the_branch() {
  local dir
  dir=$(make_case fork OPEN true firstmate-bot head)
  run_close "$dir" "$URL"
  expect_code 0 "$RC" "fork: the close should succeed"
  assert_contains "$OUT" "closed: $URL" "fork: the pull request was not closed"
  assert_contains "$OUT" "kept: branch fm/task-x1: it lives in a fork" "fork: no kept line"
  ! deleted "$dir" || fail "fork: a fork's branch was deleted"

  # The tip moved past the head after gh read it: the lease refuses the delete.
  dir=$(make_case beyond OPEN false firstmate-bot beyond)
  run_close "$dir" "$URL"
  expect_code 0 "$RC" "beyond: the close should succeed"
  assert_contains "$OUT" "kept: branch fm/task-x1: its tip is not the pull request's head $(cat "$dir/head")" "beyond: no kept line: $OUT"
  ! deleted "$dir" || fail "beyond: a branch with a commit past the head was deleted"

  dir=$(make_case collaborator OPEN false someone-else head)
  run_close "$dir" "$URL"
  expect_code 0 "$RC" "collaborator: the close should succeed"
  assert_contains "$OUT" "kept: branch fm/task-x1: the pull request's author someone-else is not the signed-in account firstmate-bot" "collaborator: no kept line"
  ! deleted "$dir" || fail "collaborator: another author's branch was deleted"
  pass "fm-pr-close keeps a fork's branch, a branch past the head, and another author's branch"
}

test_closed_merged_and_foreign_urls() {
  local dir
  dir=$(make_case closed CLOSED false firstmate-bot head)
  run_close "$dir" "$URL"
  expect_code 0 "$RC" "closed: an already-closed pull request is not an error"
  assert_contains "$OUT" "kept: branch fm/task-x1: $URL was already closed" "closed: no kept line"
  ! grep -q '^pr close' "$dir/gh.log" || fail "closed: the pull request was closed again"
  ! deleted "$dir" || fail "closed: a branch this run did not close for was deleted"

  dir=$(make_case merged MERGED false firstmate-bot head)
  run_close "$dir" "$URL"
  expect_code 1 "$RC" "merged: a merged pull request is refused"
  ! grep -q '^pr close' "$dir/gh.log" || fail "merged: a merged pull request was closed"
  ! deleted "$dir" || fail "merged: the branch was deleted"

  dir=$(make_case gitlab OPEN false firstmate-bot head)
  run_close "$dir" https://gitlab.com/example/repo/-/merge_requests/12
  expect_code 2 "$RC" "gitlab: a non-GitHub URL is refused"
  [ ! -s "$dir/gh.log" ] || fail "gitlab: gh was called for a GitLab URL"
  pass "fm-pr-close leaves an already-closed pull request's branch, refuses a merged one, and refuses other forges"
}

test_own_branch_at_head_is_deleted
test_refusals_close_but_keep_the_branch
test_closed_merged_and_foreign_urls

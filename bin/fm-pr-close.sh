#!/usr/bin/env bash
# Close a GitHub pull request firstmate is retiring unmerged, and delete its
# head branch on GitHub when that discards nothing else.
#
# GitHub deletes a head branch on merge only, so a pull request closed
# unmerged leaves its branch behind for an audit to find. `gh pr close
# --delete-branch` is not the fix: it also deletes the local branch, and when
# the caller has that branch checked out it first switches the checkout, and it
# deletes the remote branch whatever was pushed to it after the pull request's
# head was read. This command closes the pull request, then deletes the remote
# head branch only when all of these hold:
#   - this command closed it (an already-closed pull request keeps its branch,
#     since nothing here proves firstmate closed it);
#   - the head branch lives in the base repository, not a fork;
#   - the pull request's author is the signed-in gh account, so the branch is
#     firstmate's own rather than a collaborator's;
#   - the branch tip on GitHub is still the pull request's head commit, so no
#     commit beyond that head is discarded: the delete is a git push with a
#     lease on that head, which GitHub refuses for any other tip.
# It never touches a local branch or checkout; teardown owns local branches.
# It is not for the Definition of done's close-then-reopen recovery of a CI run
# an Actions outage stranded: that close must keep the branch to reopen.
# GitHub only; any other forge's URL is refused.
#
# Usage: fm-pr-close.sh <pr-url> [--comment <text>]
#   Prints `closed: <url>`, then `deleted: branch <name> of <owner>/<repo>` or
#   `kept: branch <name>: <why>`. Exits 0 once the pull request is closed by
#   this run (a kept branch included) or was already closed, 1 when it is
#   merged or the close or a read failed, and 2 for a usage error or a URL
#   that is not a GitHub pull request.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

url=
comment=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --comment)
      [ -n "${2:-}" ] || { echo "error: --comment requires text" >&2; exit 2; }
      comment=$2
      shift 2
      ;;
    -*) echo "error: unknown argument: $1" >&2; exit 2 ;;
    *)
      [ -z "$url" ] || { echo "error: usage: fm-pr-close.sh <pr-url> [--comment <text>]" >&2; exit 2; }
      url=$1
      shift
      ;;
  esac
done
[ -n "$url" ] || { echo "error: usage: fm-pr-close.sh <pr-url> [--comment <text>]" >&2; exit 2; }
if ! fm_pr_url_parse "$url" || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: $url is not a GitHub pull request URL; close it on its own forge by hand" >&2
  exit 2
fi
repo="$FM_PR_OWNER/$FM_PR_REPO"

if ! view=$(gh pr view "$FM_PR_URL" --json state,headRefName,headRefOid,isCrossRepository,author \
  --jq '[.state, .headRefName, .headRefOid, (.isCrossRepository | tostring), .author.login] | @tsv' 2>/dev/null); then
  echo "error: could not read $FM_PR_URL" >&2
  exit 1
fi
IFS=$'\t' read -r state branch head cross author <<EOF
$view
EOF

case "$state" in
  MERGED) echo "error: $FM_PR_URL is merged, so there is nothing to close" >&2; exit 1 ;;
  CLOSED)
    echo "kept: branch $branch: $FM_PR_URL was already closed, and nothing proves this run closed it"
    exit 0
    ;;
  OPEN) ;;
  *) echo "error: $FM_PR_URL reads as state '$state'" >&2; exit 1 ;;
esac

if [ -n "$comment" ]; then
  gh pr close "$FM_PR_URL" --comment "$comment" >/dev/null || { echo "error: could not close $FM_PR_URL" >&2; exit 1; }
else
  gh pr close "$FM_PR_URL" >/dev/null || { echo "error: could not close $FM_PR_URL" >&2; exit 1; }
fi
echo "closed: $FM_PR_URL"

keep() {
  echo "kept: branch $branch: $1"
  exit 0
}
case "$branch" in
  ''|*[!A-Za-z0-9._/-]*|/*|*/|*..*) keep "its name is not one this command deletes by API path" ;;
esac
fm_pr_head_valid "$head" || keep "the pull request's head commit did not read back"
[ "$cross" = false ] || keep "it lives in a fork, not in $repo"
viewer=$(gh api --hostname "$FM_PR_HOST" user --jq .login 2>/dev/null) || keep "could not read the signed-in gh account"
[ -n "$author" ] && [ "$author" = "$viewer" ] || keep "the pull request's author ${author:-unknown} is not the signed-in account ${viewer:-unknown}"
# The delete is a push with a lease on the pull request's head, so GitHub
# itself refuses it when the branch tip is anything else, even one pushed a
# moment ago. The push runs from an empty scratch repository with gh's
# credentials and never a prompt.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-close.XXXXXX") || keep "could not make a scratch repository to push the delete from"
trap 'rm -rf "$scratch"' EXIT
# A caller's GIT_DIR or GIT_WORK_TREE (a git hook sets them) would aim the
# scratch commands at the caller's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_IMPLICIT_WORK_TREE GIT_PREFIX
git init -q "$scratch" || keep "could not make a scratch repository to push the delete from"
if ! GIT_TERMINAL_PROMPT=0 git -C "$scratch" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
  push -q --force-with-lease="refs/heads/$branch:$head" \
  "https://$FM_PR_HOST/$repo.git" ":refs/heads/$branch" >/dev/null 2>&1; then
  keep "its tip is not the pull request's head $head, it is already gone, or GitHub refused the delete"
fi
echo "deleted: branch $branch of $repo"

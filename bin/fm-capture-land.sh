#!/usr/bin/env bash
# Land one skill-capture pull request end to end (fork patch,
# docs/fork-decisions/2026-10-27-capture-pr-land-command.md). A capture job
# (Nova's cron/skill-capture.sh, Cade's scripts/skill-capture.sh) turns a live
# checkout's in-place skill edits into one PR on <project>/skill-capture and
# ends its green note with "Land it: <this command>". This command:
#   1. refuses anything that is not a capture PR: the PR's repository must be the
#      origin of exactly one registered project whose config/live-checkouts entry
#      carries capture=<dir>/:<command> (bin/fm-fleet-sync.sh owns that format),
#      and its head branch must be that project's <project>/skill-capture in the
#      same repository, so it is never a general merge path;
#   2. refuses a stale open PR before recording anything: a draft, a head that is
#      not the --head the note named, a base that is not the default branch, or a
#      head not built on the current base (the gate ran on an older tree);
#   3. records the minimal task capture-<project>-<number>: a backlog item In
#      flight when this home's backlog applies (bin/fm-backlog-transition-lib.sh)
#      and a state/<id>.meta naming no worktree and no live endpoint;
#   4. merges only through bin/fm-pr-merge.sh, whose every guard (green at the
#      live head, required checks, code review, one-way door, captain hold, away
#      authority) still decides; its refusal is reported and leaves the record In
#      flight with the PR's merge poll armed, so a re-run lands it once it is fixed;
#   5. runs bin/fm-fleet-sync.sh --settle-capture <project>, which waits out a
#      capture the merge's own sync started, runs the capture command's --settle
#      in the live checkout, and fast-forwards it;
#   6. closes the record through bin/fm-teardown.sh, which retires the poll and
#      moves the backlog item to Done.
# It is idempotent: a re-run on a merged PR skips straight to the settle and the
# close, and an existing record for the PR is reused. One run per PR at a time
# (state/.capture-land-<id>.lock).
# Exit 0: landed (or already merged) and the live checkout settled and synced.
# Exit 1: refused or failed before landing; nothing merged. Exit 2: bad usage.
# Exit 3: accepted into a merge queue but not merged yet, or landed while the
# settle, sync, or close reported something to finish; re-run the same command
# after it clears.
# Usage: fm-capture-land.sh <pr-url> [--head <sha>]
set -eu

usage() { echo "usage: fm-capture-land.sh <pr-url> [--head <sha>]" >&2; }

case "${1:-}" in -h|--help) usage 2>&1; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
export FM_HOME

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

refuse() { echo "refused: $*" >&2; exit 1; }

[ "$#" = 1 ] || { [ "$#" = 3 ] && [ "$2" = --head ]; } || { usage; exit 2; }
WANT_HEAD=${3:-}
if [ -n "$WANT_HEAD" ] && ! fm_pr_head_valid "$WANT_HEAD"; then
  usage
  exit 2
fi
fm_pr_url_parse "$1" || { usage; exit 2; }
URL=$FM_PR_URL
[ "$FM_PR_PROVIDER" = github ] || refuse "$URL is not a GitHub pull request; capture jobs open theirs on GitHub"
command -v gh >/dev/null 2>&1 || refuse "gh is not on PATH"
SLUG="$FM_PR_OWNER/$FM_PR_REPO"
WANT_REPO=$(printf '%s/%s' "$FM_PR_HOST" "$SLUG" | tr '[:upper:]' '[:lower:]')

# host/owner/repo of a clone URL, lowercased: https, ssh:// and scp forms.
origin_repo() {
  local u=$1
  u=${u%/}
  u=${u%.git}
  case "$u" in
    *://*) u=${u#*://} ;;
    *:*) u=${u%%:*}/${u#*:} ;;
  esac
  u=${u#*@}
  case "$u" in *:[0-9]*/*) u=${u%%:*}/${u#*/} ;; esac
  printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]'
}

# 1. The capture project: projects with a capture= live checkout whose clone's
# origin is the PR's repository.
PROJECT=
if [ -f "$CONFIG/live-checkouts" ]; then
  while IFS= read -r name; do
    [ -d "$PROJECTS/$name" ] || continue
    origin=$(git -C "$PROJECTS/$name" remote get-url origin 2>/dev/null) || continue
    [ "$(origin_repo "$origin")" = "$WANT_REPO" ] || continue
    [ -z "$PROJECT" ] || [ "$PROJECT" = "$name" ] \
      || refuse "$SLUG is the origin of more than one capture project ($PROJECT, $name)"
    PROJECT=$name
  done < <(awk '$1 !~ /^#/ { for (i = 3; i <= NF && $i ~ /^(lock|capture)=/; i++) if ($i ~ /^capture=/) { print $1; break } }' "$CONFIG/live-checkouts")
fi
[ -n "$PROJECT" ] || refuse "$SLUG is no capture project's origin: no project in $PROJECTS with a capture= entry in $CONFIG/live-checkouts has it as its origin"
fm_task_id_creation_valid "capture-$PROJECT-$FM_PR_NUMBER" || refuse "project name $PROJECT does not make a valid task id"
ID="capture-$PROJECT-$FM_PR_NUMBER"
META="$STATE/$ID.meta"
BRANCH="$PROJECT/skill-capture"

mkdir -p "$STATE"
LOCK="$STATE/.capture-land-$ID.lock"
fm_lock_acquire_wait "$LOCK" || refuse "could not take $LOCK"
trap 'fm_lock_release "$LOCK" || true' EXIT

pr_fields() {
  gh pr view "$URL" --json state,isDraft,headRefName,baseRefName,headRefOid,isCrossRepository \
    --jq '[.state, .isDraft, .headRefName, .baseRefName, .headRefOid, .isCrossRepository] | @tsv'
}
FIELDS=$(pr_fields) || refuse "could not read $URL"
IFS=$'\t' read -r PR_STATE PR_DRAFT PR_HEAD_REF PR_BASE PR_HEAD PR_FORK <<< "$FIELDS"
[ "$PR_HEAD_REF" = "$BRANCH" ] && [ "$PR_FORK" = false ] \
  || refuse "$URL is from ${PR_HEAD_REF:-an unknown branch}, not $SLUG's capture branch $BRANCH; only capture PRs land here"

# 2-4. An open PR: preflight, record, merge.
if [ "$PR_STATE" = OPEN ]; then
  [ "$PR_DRAFT" = false ] || refuse "$URL is a draft"
  [ -z "$WANT_HEAD" ] || [ "$PR_HEAD" = "$WANT_HEAD" ] \
    || refuse "$URL is stale: its head is $PR_HEAD, not $WANT_HEAD the note named; land the newest capture note instead"
  DEFAULT=$(gh api "repos/$SLUG" --jq .default_branch) || refuse "could not read $SLUG's default branch"
  [ "$PR_BASE" = "$DEFAULT" ] || refuse "$URL targets $PR_BASE, not $SLUG's default branch $DEFAULT"
  BEHIND=$(gh api "repos/$SLUG/compare/$DEFAULT...$PR_HEAD" --jq .behind_by) \
    || refuse "could not compare $URL's head with $DEFAULT"
  [ "$BEHIND" = 0 ] \
    || refuse "$URL is stale: its head is $BEHIND commit(s) behind $DEFAULT, so its gate ran on an older tree; the next capture run rebuilds it on $DEFAULT"

  if [ -e "$META" ] || [ -L "$META" ]; then
    grep -qxF "capture_land=$URL" "$META" 2>/dev/null \
      || refuse "state/$ID.meta exists and is not this command's record for $URL"
    echo "record: reusing task $ID"
  else
    BACKLOG_RC=0
    fm_backlog_transition_applies "$CONFIG" "$DATA" ship || BACKLOG_RC=$?
    case "$BACKLOG_RC" in
      0)
        "$SCRIPT_DIR/fm-tasks-axi.sh" show "$ID" >/dev/null 2>&1 \
          || "$SCRIPT_DIR/fm-tasks-axi.sh" add "$ID" "Land $PROJECT skill capture $URL" \
            --kind ship --repo "$PROJECT" --pr "$URL" >/dev/null \
          || refuse "could not file backlog item $ID"
        "$SCRIPT_DIR/fm-tasks-axi.sh" start "$ID" >/dev/null || refuse "could not start backlog item $ID"
        ;;
      1) ;;
      *) refuse "this home's backlog cannot be read: $FM_BACKLOG_TRANSITION_ERROR" ;;
    esac
    TMP_META=$(mktemp "$STATE/.capture-land-meta.XXXXXX")
    {
      # A tmux-shaped endpoint no session holds: bin/fm-teardown.sh needs a
      # validated endpoint, and closing one that never existed is a no-op.
      printf 'window=fm-capture-land:fm-%s\n' "$ID"
      printf 'endpoint_task_id=%s\n' "$ID"
      printf 'worktree=\n'
      printf 'project=%s\n' "$PROJECTS/$PROJECT"
      printf 'kind=ship\n'
      printf 'mode=direct-PR\n'
      printf 'capture_land=%s\n' "$URL"
      printf 'spawn_gen=s%s.%s.%s\n' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
    } > "$TMP_META"
    chmod 0600 "$TMP_META"
    mv -f -- "$TMP_META" "$META"
    echo "record: task $ID"
  fi

  MERGE_RC=0
  "$SCRIPT_DIR/fm-pr-merge.sh" "$ID" "$URL" || MERGE_RC=$?
  # The forge decides what happened: a merge can land and still exit non-zero
  # (an unrecorded outcome), and a merge queue accepts without merging.
  if [ "$(gh pr view "$URL" --json state --jq .state 2>/dev/null || true)" != MERGED ]; then
    if [ "$MERGE_RC" != 0 ]; then
      echo "not landed: bin/fm-pr-merge.sh refused $URL (reasons above); task $ID stays in flight with its merge poll armed - re-run this command once the reason clears" >&2
      exit 1
    fi
    echo "queued: $URL is not merged yet; task $ID stays in flight with its merge poll armed - re-run this command once it merges" >&2
    exit 3
  fi
  [ "$MERGE_RC" = 0 ] || echo "attention: $URL merged, but bin/fm-pr-merge.sh exited $MERGE_RC (above); settling anyway" >&2
elif [ "$PR_STATE" = MERGED ]; then
  echo "already merged: $URL"
else
  [ ! -e "$META" ] || echo "note: task $ID's record stays for $URL; close it with bin/fm-teardown.sh $ID once nothing more lands from it" >&2
  refuse "$URL is $PR_STATE, not open or merged"
fi

# 5. Settle and fast-forward the live checkout.
RC=0
SYNC_OUT=$("$SCRIPT_DIR/fm-fleet-sync.sh" --settle-capture "$PROJECTS/$PROJECT" </dev/null) || RC=3
[ -z "$SYNC_OUT" ] || printf '%s\n' "$SYNC_OUT"
# Only a live checkout that ends synced, already current, or recovered went live;
# every other outcome (STUCK, a skip, edits still pending capture) is unfinished.
LIVE_LINES=$(printf '%s\n' "$SYNC_OUT" | grep -F "$PROJECT live " || true)
if [ -z "$LIVE_LINES" ] \
  || printf '%s\n' "$LIVE_LINES" | grep -Evq ': (synced|already current|recovered|settled|post-update command ran|fetch succeeded)' \
  || ! printf '%s\n' "$LIVE_LINES" | grep -Eq ': (synced|already current|recovered)'; then
  echo "attention: $PROJECT's live checkout did not settle and go live (line above); re-run this command once it clears" >&2
  RC=3
fi

# 6. Close the record.
if [ -e "$META" ]; then
  if grep -qxF "capture_land=$URL" "$META" 2>/dev/null; then
    "$SCRIPT_DIR/fm-teardown.sh" "$ID" </dev/null || {
      echo "attention: landed $URL but could not close task $ID (above); re-run this command" >&2
      RC=3
    }
  else
    echo "attention: state/$ID.meta is not this command's record for $URL, so it was left alone" >&2
    RC=3
  fi
fi
[ "$RC" != 0 ] || echo "landed: $URL; $PROJECT's live checkout is settled and synced"
exit "$RC"

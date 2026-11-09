#!/usr/bin/env bash
# fm-noticed.sh - firstmate's noticed and idea queue: problems an agent notices
# outside its task, and ideas that could make the ecosystem better.
#
# Usage:
#   fm-noticed.sh file noticed|idea <slug> --title <text> --why <text>
#                 [--from <task-or-agent>] [--repo <name>] [--evidence <text>]
#                 [--now]
#   fm-noticed.sh collect <task-id>
#   fm-noticed.sh list [noticed|idea]
#   fm-noticed.sh top3 <idea-id>...
#   fm-noticed.sh unseen
#   fm-noticed.sh shown <id>...
#   fm-noticed.sh close <id> --evidence <text> [--fixed] [--pr <url>]
#
# .agents/skills/noticed-queue/SKILL.md owns the policy: who files, when, how
# to match a duplicate, and what the Monday sweep and ranking do. This script
# owns the mechanics. Firstmate is its only caller.
#
# AN ITEM IS ITS SLUG. The task id is noticed-<slug> or idea-<slug>, and the
# backlog kind is noticed or idea, so `fm-tasks-axi.sh list --kind noticed`
# finds them. Every item is an ordinary captain hold through
# bin/fm-captain-hold.sh (kind reversible), which keeps it out of dispatch:
# nothing here ever starts work.
#
# file     File one item, or attach evidence to the item its slug already
#          names. One line per call:
#            filed: <id>       a new item, held for the captain
#            matched: <id>     already open; a dated "Seen again" line was
#                              added to its body
#            reopened: <id>    a closed noticed item came back; it is re-held
#                              (refiled fresh once Done retention archived it)
#            skipped: <id> (answered earlier)   a closed idea is never re-asked,
#                              archived or not
#          A filed or reopened noticed item joins the unseen list labelled
#          `noticed`, where it waits for the Monday triage; an idea waits for
#          the Monday ranking (top3). --now marks a noticed item urgent or
#          doing harm (money, customers, account health, security): filed,
#          matched or reopened, it joins the unseen list labelled `now`, the
#          only label the wake drain prints, and an idea refuses it. Once
#          `now`, a row stays `now` until marked shown. --from names who saw it (a
#          task id or an agent); one naming nova or sapna is refused, because
#          Sapna's agents never file into this backlog. A body rewrite takes
#          bin/fm-captain-hold.sh's per-task control lock, so it never replays
#          a body a hold or answer just changed.
# collect  Print the last `Noticed:` and the last `Idea:` line a finished task
#          left - the end-of-task lines, after any jotted mid-task - from
#          data/<task-id>/report.md, else data/<task-id>/notes.md. A report
#          line reading `none` settles that label: the notes are not read for
#          it. Prints nothing when the task left neither; exit 0 either way.
# list     The open items of one kind, or both, held or not, with the date
#          each was filed (tasks-axi's list; the sweep reads age from
#          `created`).
# top3     Record up to three ideas as this week's top picks: each must be an
#          open idea-<slug> never picked before. Picks join the unseen list
#          labelled `top idea`. One line per id: `top: <id>`, or
#          `refused: <id> (<why>)` with exit 1.
# unseen   Print what firstmate has not yet shown the captain, one
#          `<id><TAB><label><TAB><title>` line each, label `now`, `noticed`,
#          `top idea` or `fixed`. A read; bin/fm-wake-drain.sh prints its
#          `now` rows every drain, and the Monday triage reads the rest.
# shown    Mark items shown after the captain message or Monday triage that
#          brought them to him.
#          Prints `shown: <id>` for each id that was unseen.
# close    Close an item that is settled (fixed, or replaced by other work):
#          add a dated `Settled:` line with the evidence and any --pr URL,
#          mark it done, and drop it from the unseen list, except a `now`
#          row the captain has not been told yet. --fixed, which needs --pr,
#          says firstmate fixed a noticed item on its own: the item rejoins
#          the unseen list labelled `fixed`, titled `<title> - <evidence>` and
#          the PR URL, for the Monday triage's "Fixed on my own this week"
#          list, unless a `now` row keeps it; an idea refuses it. A later
#          sighting replaces a `fixed` row. Prints `closed: <id>`.
#
# State: state/noticed/unseen.tsv (the unseen list), state/noticed/picked
# (every id ever in a top 3) and state/noticed/filed (every id ever filed, so
# an item Done retention archived out of the backlog is still known), written
# under state/noticed/lock (bin/fm-wake-lib.sh's lock, with its stale-owner
# recovery).
# FM_NOTICED_NOW (YYYY-MM-DD) fixes the date for tests.
set -u
# Answer help before fm-wake-lib.sh below prepares the home's state.
case "${1:-}" in -h | --help | help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DIR="$STATE/noticed"
UNSEEN="$DIR/unseen.tsv"
PICKED="$DIR/picked"
FILED="$DIR/filed"
LOCK="$DIR/lock"
TODAY=${FM_NOTICED_NOW:-$(date -u +%Y-%m-%d)}
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"
HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
TAB=$'\t'
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

refuse() {
  printf 'fm-noticed: %s\n' "$*" >&2
  exit 2
}

one_line() {  # <name> <value>
  case "$2" in
    *[![:space:]]*) ;;
    *) refuse "$1 must not be empty" ;;
  esac
  case "$2" in
    *$'\n'* | *$'\r'*) refuse "$1 must be one line" ;;
  esac
}

valid_slug() {
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# One writer at a time, for the rest of the command.
lock_state() {
  mkdir -p "$DIR"
  fm_lock_acquire_wait_max "$LOCK" 30 || { echo "fm-noticed: $LOCK was not freed within 30s" >&2; exit 1; }
  trap 'fm_lock_release "$LOCK"' EXIT
}

shown_field() {  # <show-output> <field>: the decoded value of one shown field
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $v = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($v) if utf8::is_utf8($v);
        print $v;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

add_unseen() {  # <id> <label> <title>; call under lock_state
  grep -q "^$1$TAB" "$UNSEEN" 2>/dev/null && return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$UNSEEN"
}

drop_unseen() {  # <id>; call under lock_state
  local tmp
  [ -f "$UNSEEN" ] || return 0
  grep -q "^$1$TAB" "$UNSEEN" || return 0
  tmp=$(mktemp "$UNSEEN.XXXXXX") || exit 1
  grep -v "^$1$TAB" "$UNSEEN" > "$tmp"
  mv "$tmp" "$UNSEEN"
}

# A noticed item joins the unseen list to wait for the Monday triage, or as
# `now` when urgent; an existing `noticed` row is relabelled `now`, and a
# `fixed` row is replaced, because the item is broken again.
list_noticed() {  # <id> <title> <now 0|1>; call under lock_state
  if [ "$3" = 1 ]; then
    grep -q "^$1${TAB}now$TAB" "$UNSEEN" 2>/dev/null && return 0
    drop_unseen "$1"
    add_unseen "$1" now "$2"
  else
    ! grep -q "^$1${TAB}fixed$TAB" "$UNSEEN" 2>/dev/null || drop_unseen "$1"
    add_unseen "$1" noticed "$2"
  fi
}

# Read, extend and write back a row's full body under the per-task control
# lock bin/fm-captain-hold.sh takes for its own body writes.
append_body() {  # <id> <line>
  local lock="$STATE/.control-$1.lock" show body tmp rc=1
  fm_lock_acquire_wait_max "$lock" 30 || { echo "fm-noticed: the control lock for $1 was not freed within 30s" >&2; return 1; }
  if show=$("$TASKS" show "$1" --full) && tmp=$(mktemp "${TMPDIR:-/tmp}/fm-noticed-body.XXXXXX"); then
    body=$(shown_field "$show" body)
    printf '%s\n\n%s\n' "$body" "$2" > "$tmp" && "$TASKS" update "$1" --body-file "$tmp" >/dev/null && rc=0
    rm -f "$tmp"
  fi
  fm_lock_release "$lock"
  return "$rc"
}

hold_reason() {  # <kind> <title> <why> <from>
  local label=Noticed
  [ "$1" = idea ] && label=Idea
  printf '%s by %s on %s: %s Why it may matter: %s' "$label" "$4" "$TODAY" "$2" "$3"
}

cmd_file() {
  local kind=${1:-} slug=${2:-} title='' why='' from=firstmate repo='' evidence='' now=0 id show state
  [ $# -ge 2 ] || refuse "file needs noticed|idea and a slug"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=${2-}; shift ;;
      --why) why=${2-}; shift ;;
      --from) from=${2-}; shift ;;
      --repo) repo=${2-}; shift ;;
      --evidence) evidence=${2-}; shift ;;
      --now) now=1 ;;
      *) refuse "unknown option $1" ;;
    esac
    shift
  done
  case "$kind" in noticed | idea) ;; *) refuse "kind must be noticed or idea (got $kind)" ;; esac
  [ "$now" = 0 ] || [ "$kind" = noticed ] || refuse "--now marks an urgent noticed item; an idea waits for the Monday ranking"
  valid_slug "$slug" || refuse "slug must be lowercase-kebab (got $slug)"
  one_line --title "$title"
  one_line --why "$why"
  one_line --from "$from"
  [ -z "$evidence" ] || one_line --evidence "$evidence"
  if [[ $(printf '%s' "$from" | tr '[:upper:]' '[:lower:]') =~ (^|[^a-z])(nova|sapna)([^a-z]|$) ]]; then
    refuse "Sapna's agents never file into this backlog (--from $from)"
  fi
  id="$kind-$slug"
  lock_state
  if show=$("$TASKS" show "$id" --full 2>/dev/null); then
    state=$(shown_field "$show" state)
    if [ "$state" != "done" ]; then
      append_body "$id" "Seen again $TODAY by $from: ${evidence:-$why}" \
        || { echo "fm-noticed: could not attach evidence to $id" >&2; exit 1; }
      [ "$now" = 0 ] || list_noticed "$id" "$(shown_field "$show" title)" 1
      printf 'matched: %s\n' "$id"
      return 0
    fi
    if [ "$kind" = idea ]; then
      printf 'skipped: %s (answered earlier)\n' "$id"
      return 0
    fi
    # Reopened rows are dispatchable until held, so hold at once, and close
    # the row again if the hold fails.
    "$TASKS" reopen "$id" >/dev/null || { echo "fm-noticed: could not reopen $id" >&2; exit 1; }
    if ! "$HOLD" hold "$id" --kind reversible --reason "$(hold_reason "$kind" "$title" "$why" "$from")" >/dev/null; then
      "$TASKS" "done" "$id" >/dev/null 2>&1 \
        || echo "fm-noticed: $id is reopened but unheld; hold or close it before anything dispatches" >&2
      echo "fm-noticed: could not re-hold $id" >&2
      exit 1
    fi
    append_body "$id" "Back $TODAY, seen by $from: ${evidence:-$why}" \
      || { echo "fm-noticed: $id is re-held but its new evidence was not attached" >&2; exit 1; }
    list_noticed "$id" "$title" "$now"
    printf 'reopened: %s\n' "$id"
    return 0
  fi
  local body outcome=filed
  if grep -Fxq -- "$id" "$FILED" 2>/dev/null; then
    # Filed before, and archived out of the backlog since it closed.
    if [ "$kind" = idea ]; then
      printf 'skipped: %s (answered earlier)\n' "$id"
      return 0
    fi
    outcome=reopened
  fi
  body="$( [ "$kind" = idea ] && echo Idea || echo Noticed ) $TODAY by $from: $title
Why it may matter: $why"
  [ "$outcome" = filed ] || body="$body
Back after an earlier $id closed; its record is in the Done archive."
  [ -z "$evidence" ] || body="$body
Evidence: $evidence"
  "$TASKS" add "$id" "$title" --kind "$kind" ${repo:+--repo "$repo"} --body "$body" >/dev/null \
    || { echo "fm-noticed: could not add $id" >&2; exit 1; }
  "$HOLD" hold "$id" --kind reversible --reason "$(hold_reason "$kind" "$title" "$why" "$from")" >/dev/null \
    || { echo "fm-noticed: $id was added but could not be held; hold it with bin/fm-captain-hold.sh before anything dispatches" >&2; exit 1; }
  grep -Fxq -- "$id" "$FILED" 2>/dev/null || printf '%s\n' "$id" >> "$FILED"
  [ "$kind" = noticed ] && list_noticed "$id" "$title" "$now"
  printf '%s: %s\n' "$outcome" "$id"
}

cmd_collect() {
  local id=${1:-} file label line
  [ $# -eq 1 ] || refuse "collect needs one task id"
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "bad task id $id"
  for label in Noticed Idea; do
    for file in "$DATA/$id/report.md" "$DATA/$id/notes.md"; do
      [ -f "$file" ] || continue
      line=$(sed -nE "s/^[[:space:]]*([-*][[:space:]]+)?(\*\*)?$label:(\*\*)?[[:space:]]*//p" "$file" | tail -1)
      [ -n "$line" ] || continue
      if ! printf '%s\n' "$line" | grep -qiE '^(none\.?|n/a)?[[:space:]]*$'; then
        printf '%s: %s (%s)\n' "$label" "$line" "${file#"$DATA"/}"
      fi
      break
    done
  done
  return 0
}

cmd_list() {
  local kind
  case "${1:-}" in
    '') set -- noticed idea ;;
    noticed | idea) ;;
    *) refuse "list takes noticed or idea" ;;
  esac
  for kind in "$@"; do
    "$TASKS" list --state queued --kind "$kind" --fields created,held
    "$TASKS" list --state in_flight --kind "$kind" --fields created
  done
}

cmd_top3() {
  local id show status=0
  [ $# -ge 1 ] && [ $# -le 3 ] || refuse "top3 takes one to three idea ids"
  lock_state
  for id in "$@"; do
    case "$id" in idea-*) ;; *) printf 'refused: %s (not an idea)\n' "$id"; status=1; continue ;; esac
    if grep -Fxq -- "$id" "$PICKED" 2>/dev/null; then
      printf 'refused: %s (already in an earlier top 3)\n' "$id"; status=1; continue
    fi
    if ! "$HOLD" open "$id" >/dev/null 2>&1 || ! show=$("$TASKS" show "$id" 2>/dev/null); then
      printf 'refused: %s (not an open idea)\n' "$id"; status=1; continue
    fi
    printf '%s\n' "$id" >> "$PICKED"
    add_unseen "$id" "top idea" "$(shown_field "$show" title)"
    printf 'top: %s\n' "$id"
  done
  return "$status"
}

cmd_unseen() {
  [ $# -eq 0 ] || refuse "unseen takes no arguments"
  [ -f "$UNSEEN" ] && cat "$UNSEEN"
  return 0
}

cmd_shown() {
  local id
  [ $# -ge 1 ] || refuse "shown needs at least one id"
  lock_state
  [ -f "$UNSEEN" ] || return 0
  for id in "$@"; do
    grep -q "^$id$TAB" "$UNSEEN" || continue
    drop_unseen "$id"
    printf 'shown: %s\n' "$id"
  done
}

cmd_close() {
  local id=${1:-} evidence='' fixed=0 pr='' settled show title=''
  [ $# -ge 1 ] || refuse "close needs an id"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence) evidence=${2-}; shift ;;
      --fixed) fixed=1 ;;
      --pr) pr=${2-}; shift ;;
      *) refuse "unknown option $1" ;;
    esac
    shift
  done
  case "$id" in noticed-* | idea-*) ;; *) refuse "close takes a noticed- or idea- id (got $id)" ;; esac
  one_line --evidence "$evidence"
  [ -z "$pr" ] || one_line --pr "$pr"
  [ "$fixed" = 0 ] || [ "${id%%-*}" = noticed ] || refuse "--fixed records a noticed item firstmate fixed; an idea waits for his pick"
  [ "$fixed" = 0 ] || [ -n "$pr" ] || refuse "--fixed needs --pr <url>, so the Monday triage can link the fix"
  settled="Settled $TODAY: $evidence${pr:+ ($pr)}"
  [ "$fixed" = 0 ] || settled="$settled Fixed by firstmate on its own."
  lock_state
  if [ "$fixed" = 1 ]; then
    show=$("$TASKS" show "$id" 2>/dev/null) || { echo "fm-noticed: could not read $id" >&2; exit 1; }
    title=$(shown_field "$show" title)
  fi
  append_body "$id" "$settled" || { echo "fm-noticed: could not record the evidence on $id" >&2; exit 1; }
  "$TASKS" "done" "$id" >/dev/null || { echo "fm-noticed: could not close $id" >&2; exit 1; }
  # An urgent row he has not been told about yet stays for the drain.
  if ! grep -q "^$id${TAB}now$TAB" "$UNSEEN" 2>/dev/null; then
    drop_unseen "$id"
    [ "$fixed" = 0 ] || add_unseen "$id" fixed "$title - $evidence ($pr)"
  fi
  printf 'closed: %s\n' "$id"
}

case "${1:-}" in
  file) shift; cmd_file "$@" ;;
  close) shift; cmd_close "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  list) shift; cmd_list "$@" ;;
  top3) shift; cmd_top3 "$@" ;;
  unseen) shift; cmd_unseen "$@" ;;
  shown) shift; cmd_shown "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac

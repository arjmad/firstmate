#!/usr/bin/env bash
# fm-noticed.sh - firstmate's noticed and idea queue: problems an agent notices
# outside its task, and ideas that could make the ecosystem better.
#
# Usage:
#   fm-noticed.sh file noticed|idea <slug> --title <text> --why <text>
#                 [--from <task-or-agent>] [--repo <name>] [--evidence <text>]
#   fm-noticed.sh collect <task-id>
#   fm-noticed.sh list [noticed|idea]
#   fm-noticed.sh top3 <idea-id>...
#   fm-noticed.sh unseen
#   fm-noticed.sh shown <id>...
#
# .agents/skills/noticed-queue/SKILL.md owns the policy: who files, when, how
# to match a duplicate, and what the Monday sweep and ranking do. This script
# owns the mechanics. Firstmate is its only caller.
#
# AN ITEM IS ITS SLUG. The task id is noticed-<slug> or idea-<slug>, and the
# backlog kind is noticed or idea, so `fm-tasks-axi.sh list --kind noticed`
# finds them. Every item is an ordinary captain hold through
# bin/fm-captain-hold.sh (kind reversible, no default, so it never releases
# itself), which keeps it out of dispatch: nothing here ever starts work.
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
#          A filed or reopened noticed item joins the unseen list; an idea
#          waits for the Monday ranking (top3). --from names who saw it (a
#          task id or an agent); nova and sapna are refused, because Sapna's
#          agents never file into this backlog.
# collect  Print the first `Noticed:` and the first `Idea:` line a finished
#          task left, read from data/<task-id>/report.md, then
#          data/<task-id>/notes.md. A line whose text is `none` is skipped.
#          Prints nothing when the task left neither; exit 0 either way.
# list     The open items of one kind, or both, with the date each was filed
#          (tasks-axi's list; the sweep reads age from `created`).
# top3     Record up to three ideas as this week's top picks: each must be an
#          open idea-<slug> never picked before. Picks join the unseen list
#          labelled `top idea`. One line per id: `top: <id>`, or
#          `refused: <id> (<why>)` with exit 1.
# unseen   Print what firstmate has not yet shown the captain, one
#          `<id><TAB><label><TAB><title>` line each, label `noticed` or
#          `top idea`. A read; bin/fm-wake-drain.sh prints it every drain.
# shown    Mark items shown after the captain reply that mentions them.
#          Prints `shown: <id>` for each id that was unseen.
#
# State: state/noticed/unseen.tsv (the unseen list), state/noticed/picked
# (every id ever in a top 3) and state/noticed/filed (every id ever filed, so
# an item Done retention archived out of the backlog is still known), written
# under state/noticed/lock.
# FM_NOTICED_NOW (YYYY-MM-DD) fixes the date for tests.
set -u

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

# One writer at a time. A lock older than a minute is a dead writer's.
lock_state() {
  local tries=0
  mkdir -p "$DIR"
  until mkdir "$LOCK" 2>/dev/null; do
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || { echo "fm-noticed: $LOCK is held" >&2; exit 1; }
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
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

append_body() {  # <id> <show-output> <line>
  local body tmp
  body=$(shown_field "$2" body)
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-noticed-body.XXXXXX") || exit 1
  printf '%s\n\n%s\n' "$body" "$3" > "$tmp"
  "$TASKS" update "$1" --body-file "$tmp" >/dev/null
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

hold_reason() {  # <kind> <title> <why> <from>
  local label=Noticed
  [ "$1" = idea ] && label=Idea
  printf '%s by %s on %s: %s Why it may matter: %s' "$label" "$4" "$TODAY" "$2" "$3"
}

cmd_file() {
  local kind=${1:-} slug=${2:-} title='' why='' from=firstmate repo='' evidence='' id show state
  [ $# -ge 2 ] || refuse "file needs noticed|idea and a slug"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=${2-}; shift ;;
      --why) why=${2-}; shift ;;
      --from) from=${2-}; shift ;;
      --repo) repo=${2-}; shift ;;
      --evidence) evidence=${2-}; shift ;;
      *) refuse "unknown option $1" ;;
    esac
    shift
  done
  case "$kind" in noticed | idea) ;; *) refuse "kind must be noticed or idea (got $kind)" ;; esac
  valid_slug "$slug" || refuse "slug must be lowercase-kebab (got $slug)"
  one_line --title "$title"
  one_line --why "$why"
  one_line --from "$from"
  [ -z "$evidence" ] || one_line --evidence "$evidence"
  case "$(printf '%s' "$from" | tr '[:upper:]' '[:lower:]')" in
    nova | sapna | nova:* | sapna:*) refuse "Sapna's agents never file into this backlog (--from $from)" ;;
  esac
  id="$kind-$slug"
  lock_state
  if show=$("$TASKS" show "$id" --full 2>/dev/null); then
    state=$(shown_field "$show" state)
    if [ "$state" != "done" ]; then
      append_body "$id" "$show" "Seen again $TODAY by $from: ${evidence:-$why}" \
        || { echo "fm-noticed: could not attach evidence to $id" >&2; exit 1; }
      printf 'matched: %s\n' "$id"
      return 0
    fi
    if [ "$kind" = idea ]; then
      printf 'skipped: %s (answered earlier)\n' "$id"
      return 0
    fi
    "$TASKS" reopen "$id" >/dev/null || { echo "fm-noticed: could not reopen $id" >&2; exit 1; }
    show=$("$TASKS" show "$id" --full) || exit 1
    append_body "$id" "$show" "Back $TODAY, seen by $from: ${evidence:-$why}" \
      || { echo "fm-noticed: could not attach evidence to $id" >&2; exit 1; }
    "$HOLD" hold "$id" --kind reversible --reason "$(hold_reason "$kind" "$title" "$why" "$from")" >/dev/null \
      || { echo "fm-noticed: could not re-hold $id" >&2; exit 1; }
    add_unseen "$id" noticed "$title"
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
  [ "$kind" = noticed ] && add_unseen "$id" noticed "$title"
  printf '%s: %s\n' "$outcome" "$id"
}

cmd_collect() {
  local id=${1:-} file label line
  [ $# -eq 1 ] || refuse "collect needs one task id"
  valid_slug "$id" || [[ $id =~ ^[A-Za-z0-9._-]+$ ]] || refuse "bad task id $id"
  for label in Noticed Idea; do
    for file in "$DATA/$id/report.md" "$DATA/$id/notes.md"; do
      [ -f "$file" ] || continue
      line=$(sed -nE "s/^[[:space:]]*([-*][[:space:]]+)?(\*\*)?$label:(\*\*)?[[:space:]]*//p" "$file" \
        | grep -viE '^(none\.?|n/a)?[[:space:]]*$' | head -1)
      if [ -n "$line" ]; then
        printf '%s: %s (%s)\n' "$label" "$line" "${file#"$DATA"/}"
        break
      fi
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
    "$TASKS" list --state held --kind "$kind" --fields created
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
  local id tmp
  [ $# -ge 1 ] || refuse "shown needs at least one id"
  lock_state
  [ -f "$UNSEEN" ] || return 0
  for id in "$@"; do
    grep -q "^$id$TAB" "$UNSEEN" || continue
    tmp=$(mktemp "$UNSEEN.XXXXXX") || exit 1
    grep -v "^$id$TAB" "$UNSEEN" > "$tmp"
    mv "$tmp" "$UNSEEN"
    printf 'shown: %s\n' "$id"
  done
}

case "${1:-}" in
  file) shift; cmd_file "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  list) shift; cmd_list "$@" ;;
  top3) shift; cmd_top3 "$@" ;;
  unseen) shift; cmd_unseen "$@" ;;
  shown) shift; cmd_shown "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac

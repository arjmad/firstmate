#!/usr/bin/env bash
# fm-noticed.sh - firstmate's noticed and idea queue: problems an agent notices
# outside its task, and ideas that could make the ecosystem better.
#
# Usage:
#   fm-noticed.sh file noticed|idea <slug> --title <text> --why <text>
#                 [--from <task-or-agent>] [--repo <name>] [--evidence <text>]
#                 [--now] [--call ask-first|ruling|retire|machinery]
#   fm-noticed.sh collect <task-id>
#   fm-noticed.sh list [noticed|idea]
#   fm-noticed.sh unseen
#   fm-noticed.sh shown <id>...
#   fm-noticed.sh close <id> --evidence <text> [--fixed --pr <url> | --dropped]
#   fm-noticed.sh waiting [--shown <id>...]
#
# .agents/skills/noticed-queue/SKILL.md owns the policy: who files, when, how
# to match a duplicate, and what the Monday sweep and triage do. This script
# owns the mechanics. Firstmate is its only caller, directly or through
# bin/fm-teardown.sh, which files a scratch checkout it kept.
#
# AN ITEM IS ITS SLUG. The task id is noticed-<slug> or idea-<slug>, and the
# backlog kind is noticed or idea, so `fm-tasks-axi.sh list --kind noticed`
# finds them. A noticed item is routine by default: the fleet's own work,
# held for no one. An idea, and a noticed item filed --call, is an ordinary
# captain hold through bin/fm-captain-hold.sh (kind reversible), which keeps
# it out of dispatch (fork patches,
# docs/fork-decisions/2026-11-11-calls-grouped-by-what-it-takes.md and
# docs/fork-decisions/2026-11-17-noticed-routine-default.md).
# Nothing here ever starts work.
#
# file     File one item, or attach evidence to the item its slug already
#          names. One line per call:
#            filed: <id>       a new item
#            matched: <id>     already open; a dated "Seen again" line was
#                              added to its body
#            reopened: <id>    a closed noticed item came back, routine or
#                              re-held as this filing says (refiled fresh
#                              once Done retention archived it); a routine
#                              reopen that lifted the captain hold the item
#                              closed with adds ` (lifted its earlier captain
#                              hold)`
#            skipped: <id> (answered earlier)   a closed idea is never re-asked,
#                              archived or not; in a secondmate home, neither
#                              is an idea already handed to the main home
#            handed-up: <id>   in a secondmate home, an idea or a --call
#                              item went to the main home instead (below)
#          In a secondmate home (a .fm-secondmate-home marker) an idea or a
#          --call item is not filed here: it is appended to the parent channel
#          through bin/fm-parent-channel-lib.sh as one
#          `needs-decision [key=noticed-queue-<id>]: noticed-queue <kind> <id>
#          [(call: <kind>)] [(now: ...)]: <title> - why: ... - from: ...` line
#          with any repo and evidence fields, and no local row is kept. An id
#          with an open row in this home files locally as before, because that
#          row tracks this home's own work; a --call there holds it, and
#          bin/fm-captain-hold.sh publishes the hold to the main home.
#          Evidence is cut to fit the channel's 1200-byte note, and an item
#          whose other fields do not fit is refused (exit 2) before anything is
#          sent. A channel that cannot be written exits 1. Routine noticed
#          items still file locally.
#          A noticed item is filed routine unless --call is given: firstmate
#          fixes or drops it on its own, so the row is not held, its owner is
#          the fleet, and it joins no unseen list until `close --fixed` or
#          `--dropped` lists it for the Monday triage. --call <kind> holds a
#          noticed item for the captain instead, naming the call it needs:
#          ask-first (an ask-first action), ruling (a rule or ruling),
#          retire (retiring a part) or machinery (adding new machinery); its
#          hold reason records the kind, and a filed or reopened held item
#          joins the unseen list labelled `noticed`, where it waits for the
#          Monday triage. An idea is always held, gets no unseen row, and the
#          Monday sweep reads it from `list idea`; it refuses --call. --now
#          marks a noticed item urgent or doing harm (money, customers,
#          account health, security), routine or held: filed, matched or
#          reopened, it joins the unseen list labelled `now`, the only label
#          the wake drain prints, and an idea refuses it. Once `now`, a row
#          stays `now` until marked shown. --routine is accepted for older
#          callers and changes nothing; it refuses an idea and --call. An
#          open item filed again gains its evidence, and --call also holds
#          it when it is not held yet.
#          --from names who saw it (a
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
# unseen   Print what firstmate has not yet shown the captain, one
#          `<id><TAB><label><TAB><title>` line each, label `now`, `noticed`,
#          `fixed` or `dropped`. bin/fm-wake-drain.sh prints its `now` rows
#          every drain, and the Monday triage reads the rest. It tidies the
#          list first: a `noticed` row whose item is no longer open (closed
#          by any path, or archived) leaves it, and a title an older `close`
#          split over two lines with tasks-axi's truncation pointer is
#          rejoined, the pointer cut to `...`. A backlog read that fails or
#          cannot be parsed prunes nothing.
# shown    Mark items shown after the captain message or Monday triage that
#          brought them to him.
#          Prints `shown: <id>` for each id that was unseen.
# close    Close an item that is settled (fixed, or replaced by other work):
#          add a dated `Settled:` line with the evidence and any --pr URL,
#          mark it done, and drop it from the unseen list, except a `now`
#          row the captain has not been told yet. --fixed, which needs --pr,
#          says firstmate fixed a noticed item on its own: the item rejoins
#          the unseen list labelled `fixed`, titled `<title> - <evidence>` and
#          the PR URL, for the Monday triage's "Handled for you" list,
#          unless a `now` row keeps it; an idea refuses it. --dropped says
#          firstmate dropped a noticed item on its own: it joins that list
#          labelled `dropped`, titled `<title> - <evidence>`; an idea refuses
#          it, and it does not combine with --fixed. A later sighting replaces
#          a `fixed` or `dropped` row. A row already closed (a routine item
#          whose ship's teardown closed it) is recorded without a second
#          close. Prints `closed: <id>`.
# waiting  Print each captain call held 14 days or more with no date - the
#          canonical snapshot's `aged` bucket, read through
#          bin/fm-fleet-snapshot.sh --contribution-input - that no Monday
#          triage has shown yet, one `<id><TAB><days held><TAB><title>` line
#          each, for the triage's "Waiting 2+ weeks" section. --shown marks
#          ids shown, so each call shows there once; prints `shown: <id>`.
#
# State: state/noticed/unseen.tsv (the unseen list), state/noticed/filed (every id ever filed, so
# an item Done retention archived out of the backlog is still known), and
# state/noticed/waiting-shown (the calls a triage showed as waiting), written
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
FILED="$DIR/filed"
WAITING_SHOWN="$DIR/waiting-shown"
LOCK="$DIR/lock"
TODAY=${FM_NOTICED_NOW:-$(date -u +%Y-%m-%d)}
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"
HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
TAB=$'\t'
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

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
  # Drop the entry with the second half of a title an older close split off
  # it, paired as tidy_unseen pairs them.
  awk -F "$TAB" -v id="$1" '
    $1 == id && NF >= 3 { skip = ($2 == "fixed" || $2 == "dropped") && length($3) == 80; next }
    skip && /^\.\.\. \(truncated, [0-9]+ chars total - use [^)]*to see complete text\)/ { skip = 0; next }
    { skip = 0; print }
  ' "$UNSEEN" > "$tmp"
  mv "$tmp" "$UNSEEN"
}

# A noticed item joins the unseen list to wait for the Monday triage, or as
# `now` when urgent; an existing `noticed` row is relabelled `now`, and a
# `fixed` or `dropped` row is replaced, because the item is broken again.
list_noticed() {  # <id> <title> <now 0|1>; call under lock_state
  if [ "$3" = 1 ]; then
    grep -q "^$1${TAB}now$TAB" "$UNSEEN" 2>/dev/null && return 0
    drop_unseen "$1"
    add_unseen "$1" now "$2"
  else
    ! grep -Eq "^$1$TAB(fixed|dropped)$TAB" "$UNSEEN" 2>/dev/null || drop_unseen "$1"
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

# In a secondmate home, hand an idea or a --call item to the main home on the
# parent channel instead of holding it here, because the main home's Monday
# sweep and answer tools never read a mate backlog (docs/secondmate-parent-channel.md
# "Ideas and captain calls belong to the main home"). The line is a
# needs-decision keyed noticed-queue-<id>, a key no backlog row carries,
# holding every field the main home refiles it from; the main home closes it
# with bin/fm-send.sh --resolve-key once filed. Returns 1 in a main home, or
# when this home has an open row of the id, which then file locally as before;
# exits 1 when the channel cannot be written, so the item is never dropped.
hand_up_to_parent() {  # <id> <kind> <title> <why> <from> <repo> <evidence> <call> <now>
  local id=$1 key="noticed-queue-$1" rc=0 fields head room
  # A main home files locally, whatever the item's length.
  fm_parent_channel_home_id "$FM_HOME" >/dev/null || rc=$?
  [ "$rc" != 1 ] || return 1
  rc=0
  # An open row here tracks work this home owns, such as its own kept
  # checkouts, so it stays on the local path: the evidence attaches, and a
  # --call holds it through bin/fm-captain-hold.sh, which publishes that hold
  # to the main home, so the decision still goes up and the record stays here.
  if show=$("$TASKS" show "$id" --full 2>/dev/null) && [ "$(shown_field "$show" state)" != "done" ]; then
    return 1
  fi
  # An idea handed up before, or filed and closed here, is never re-asked, as
  # in a main home.
  if [ "$2" = idea ] && grep -Fxq -- "$id" "$FILED" 2>/dev/null; then
    printf 'skipped: %s (handed to the main home or answered earlier)\n' "$id"
    return 0
  fi
  # The call and urgency lead, so the channel's length cap can only cut evidence.
  head="$2 $id${8:+ (call: $8)}"
  [ "$9" = 0 ] || head="$head (now: urgent or doing harm)"
  fields="$head: $3 - why: $4 - from: $5${6:+ - repo: $6}"
  # The channel keeps 1200 bytes of a note: evidence takes only what is left,
  # and an item whose own fields do not fit is refused before anything is sent.
  room=$((1200 - $(LC_ALL=C; printf '%s' "${#fields}")))
  [ "$room" -ge 0 ] || refuse "$id is too long to hand to the main home; shorten its title or why"
  # The byte cut may split a multibyte character; drop its bytes until the
  # evidence is valid UTF-8 again.
  [ -z "$7" ] || [ "$room" -eq 0 ] || fields="$fields$(
    LC_ALL=C
    ev=$(printf '%s' " - evidence: $7" | cut -b1-"$room")
    while [ -n "$ev" ] && ! printf '%s' "$ev" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; do ev=${ev%?}; done
    printf '%s' "$ev"
  )"
  fm_parent_channel_report "$FM_HOME" "$STATE" \
    "needs-decision [key=$key]: noticed-queue $(fm_parent_channel_clean_note "$fields")" "$key" || rc=$?
  case "$rc" in
    0)
      # An idea is recorded as filed, so a later sighting is skipped above; a
      # noticed call that comes back is asked again, as a main home reopens it.
      if [ "$2" = idea ]; then
        lock_state
        grep -Fxq -- "$id" "$FILED" 2>/dev/null || printf '%s\n' "$id" >> "$FILED"
      fi
      printf 'handed-up: %s\n' "$id"
      return 0
      ;;
    1) return 1 ;;
  esac
  echo "fm-noticed: this secondmate home could not hand $id to the main home on its parent channel (rc=$rc); hand it up as a fleet-handoff notice instead" >&2
  exit 1
}

hold_reason() {  # <kind> <title> <why> <from> [<call>]
  local label=Noticed
  [ "$1" = idea ] && label=Idea
  printf '%s by %s on %s%s: %s Why it may matter: %s' "$label" "$4" "$TODAY" "${5:+ (call: $5)}" "$2" "$3"
}

cmd_file() {
  local kind=${1:-} slug=${2:-} title='' why='' from=firstmate repo='' evidence='' now=0 routine=0 old_routine=0 call='' call_given=0 id show state
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
      --call) call=${2-}; call_given=1; shift ;;
      --routine) old_routine=1 ;;
      *) refuse "unknown option $1" ;;
    esac
    shift
  done
  case "$kind" in noticed | idea) ;; *) refuse "kind must be noticed or idea (got $kind)" ;; esac
  [ "$now" = 0 ] || [ "$kind" = noticed ] || refuse "--now marks an urgent noticed item; an idea waits for the Monday triage"
  [ "$old_routine" = 0 ] || [ "$kind" = noticed ] || refuse "--routine files a noticed item firstmate fixes or drops; an idea waits for the Monday triage"
  if [ "$call_given" = 1 ]; then
    case "$call" in ask-first | ruling | retire | machinery) ;; *) refuse "--call must be ask-first, ruling, retire or machinery (got $call)" ;; esac
    [ "$kind" = noticed ] || refuse "--call holds a noticed item; every idea is already held for the captain"
    [ "$old_routine" = 0 ] || refuse "--call holds the item for the captain; --routine files it as the fleet's"
  fi
  # A noticed item is routine unless --call names the call it needs from him.
  [ "$kind" = noticed ] && [ -z "$call" ] && routine=1
  valid_slug "$slug" || refuse "slug must be lowercase-kebab (got $slug)"
  one_line --title "$title"
  one_line --why "$why"
  one_line --from "$from"
  [ -z "$evidence" ] || one_line --evidence "$evidence"
  if [[ $(printf '%s' "$from" | tr '[:upper:]' '[:lower:]') =~ (^|[^a-z])(nova|sapna)([^a-z]|$) ]]; then
    refuse "Sapna's agents never file into this backlog (--from $from)"
  fi
  id="$kind-$slug"
  if [ "$routine" = 0 ]; then
    hand_up_to_parent "$id" "$kind" "$title" "$why" "$from" "$repo" "$evidence" "$call" "$now" && return 0
  fi
  lock_state
  if show=$("$TASKS" show "$id" --full 2>/dev/null); then
    state=$(shown_field "$show" state)
    if [ "$state" != "done" ]; then
      append_body "$id" "Seen again $TODAY by $from: ${evidence:-$why}" \
        || { echo "fm-noticed: could not attach evidence to $id" >&2; exit 1; }
      if [ -n "$call" ] && [ "$(shown_field "$show" held)" != yes ]; then
        # An open routine row that turns out to need his call is held now.
        "$HOLD" hold "$id" --kind reversible --reason "$(hold_reason "$kind" "$title" "$why" "$from" "$call")" >/dev/null \
          || { echo "fm-noticed: $id is open but could not be held; hold it with bin/fm-captain-hold.sh before anything dispatches" >&2; exit 1; }
        append_body "$id" "Held for the captain $TODAY (call: $call)." \
          || { echo "fm-noticed: $id is held but its hold was not noted in its body" >&2; exit 1; }
        list_noticed "$id" "$(shown_field "$show" title)" "$now"
      elif [ "$now" = 1 ]; then
        list_noticed "$id" "$(shown_field "$show" title)" 1
      fi
      printf 'matched: %s\n' "$id"
      return 0
    fi
    if [ "$kind" = idea ]; then
      printf 'skipped: %s (answered earlier)\n' "$id"
      return 0
    fi
    "$TASKS" reopen "$id" >/dev/null || { echo "fm-noticed: could not reopen $id" >&2; exit 1; }
    if [ "$routine" = 1 ]; then
      # A reopen restores the hold it closed with, even one whose date has
      # passed; a routine recurrence is the fleet's, so lift it first, and say
      # so, because the caller cannot see that the closed row was a call.
      local lifted=''
      case "$(shown_field "$("$TASKS" show "$id" 2>/dev/null)" hold_kind)" in '' | - | null) ;; *)
        "$TASKS" unhold "$id" >/dev/null || { echo "fm-noticed: $id is reopened but still held; unhold it before anything else" >&2; exit 1; }
        lifted=' (lifted its earlier captain hold)' ;;
      esac
      "$TASKS" owner "$id" fleet >/dev/null \
        || { echo "fm-noticed: $id is reopened but its owner could not be set to the fleet" >&2; exit 1; }
      append_body "$id" "Back $TODAY, seen by $from: ${evidence:-$why}${lifted:+ Its earlier captain hold was lifted; it is routine now.}" \
        || { echo "fm-noticed: $id is reopened but its new evidence was not attached" >&2; exit 1; }
      # Broken again: its fix or drop no longer stands.
      ! grep -Eq "^$id$TAB(fixed|dropped)$TAB" "$UNSEEN" 2>/dev/null || drop_unseen "$id"
      [ "$now" = 0 ] || list_noticed "$id" "$title" 1
      printf 'reopened: %s%s\n' "$id" "$lifted"
      return 0
    fi
    # Reopened rows are dispatchable until held, so hold at once, and close
    # the row again if the hold fails.
    if ! "$HOLD" hold "$id" --kind reversible --reason "$(hold_reason "$kind" "$title" "$why" "$from" "$call")" >/dev/null; then
      "$TASKS" "done" "$id" >/dev/null 2>&1 \
        || echo "fm-noticed: $id is reopened but unheld; hold or close it before anything dispatches" >&2
      echo "fm-noticed: could not re-hold $id" >&2
      exit 1
    fi
    append_body "$id" "Back $TODAY, seen by $from: ${evidence:-$why} Held for the captain (call: $call)." \
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
  if [ "$routine" = 1 ]; then
    "$TASKS" add "$id" "$title" --kind "$kind" --owner fleet ${repo:+--repo "$repo"} --body "$body
Routine: firstmate fixes or drops this on its own." >/dev/null \
      || { echo "fm-noticed: could not add $id" >&2; exit 1; }
    grep -Fxq -- "$id" "$FILED" 2>/dev/null || printf '%s\n' "$id" >> "$FILED"
    ! grep -Eq "^$id$TAB(fixed|dropped)$TAB" "$UNSEEN" 2>/dev/null || drop_unseen "$id"
    [ "$now" = 0 ] || list_noticed "$id" "$title" 1
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi
  "$TASKS" add "$id" "$title" --kind "$kind" ${repo:+--repo "$repo"} --body "$body" >/dev/null \
    || { echo "fm-noticed: could not add $id" >&2; exit 1; }
  "$HOLD" hold "$id" --kind reversible --reason "$(hold_reason "$kind" "$title" "$why" "$from" "$call")" >/dev/null \
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

# The ids of every open (queued or in-flight) backlog row, one per line, read
# from one listing of every row; fails when the listing fails, or unless its
# count line, its table's size and its rows agree and every row carries an id,
# a known state, and the table's five columns.
open_row_ids() {
  local listing
  listing=$("$TASKS" list --limit 1000000 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk '
    /^count: [0-9]+$/ && count == "" { count = $2 + 0; next }
    /^tasks\[[0-9]+\]\{id,state,/ { size = substr($0, 7); sub(/\].*/, "", size); size += 0; rows = 1; table = 1; next }
    rows && /^  / {
      n++
      nf = split(substr($0, 3), f, ",")
      if (f[1] ~ /^"[^"]*"$/) f[1] = substr(f[1], 2, length(f[1]) - 2)
      if (nf < 5 || f[1] !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || f[2] !~ /^(queued|in_flight|done)$/) bad = 1
      if (f[2] == "queued" || f[2] == "in_flight") ids = ids f[1] "\n"
      next
    }
    { rows = 0 }
    END {
      if (bad || count == "" || (table && size != count) || (count > 0 && !table) || n != count) exit 1
      printf "%s", ids
    }'
}

# Rewrite the unseen list as `unseen` describes; call under lock_state.
tidy_unseen() {
  local open_ids='' prune_ok=1 tmp
  [ -s "$UNSEEN" ] || return 0
  if grep -q "^[^$TAB]*${TAB}noticed$TAB" "$UNSEEN"; then
    open_ids=$(open_row_ids) || prune_ok=0
  fi
  tmp=$(mktemp "$UNSEEN.XXXXXX") || return 1
  if OPEN_IDS="$open_ids" awk -v prune="$prune_ok" -F "$TAB" '
    BEGIN {
      POINTER = "^\\.\\.\\. \\(truncated, [0-9]+ chars total - use [^)]*to see complete text\\)"
      n = split(ENVIRON["OPEN_IDS"], ids, "\n"); for (i = 1; i <= n; i++) if (ids[i] != "") open[ids[i]] = 1
    }
    function flush() {
      if (entry == "") return
      split(entry, f, "\t")
      if (!(prune && f[2] == "noticed" && !(f[1] in open))) print entry
      entry = ""
    }
    $0 ~ /^[^\t]+\t(now|noticed|fixed|dropped)\t/ { flush(); entry = $0; joinable = ($2 == "fixed" || $2 == "dropped") && length($3) == 80; next }
    # The second half of a title tasks-axi cut at 80 characters, right after
    # the fixed or dropped entry it was cut from; any other line stays as it is.
    joinable && $0 ~ POINTER {
      line = $0
      sub(POINTER, "...", line)
      sub(/[ ]+$/, "", entry)
      entry = entry line
      joinable = 0
      next
    }
    { flush(); print; joinable = 0 }
    END { flush() }
  ' "$UNSEEN" > "$tmp"; then
    if cmp -s "$tmp" "$UNSEEN"; then rm -f "$tmp"; else mv "$tmp" "$UNSEEN"; fi
  else
    rm -f "$tmp"
    return 1
  fi
}

cmd_unseen() {
  [ $# -eq 0 ] || refuse "unseen takes no arguments"
  [ -f "$UNSEEN" ] || return 0
  lock_state
  tidy_unseen || echo "fm-noticed: could not tidy $UNSEEN; listing it as it is" >&2
  cat "$UNSEEN"
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
  local id=${1:-} evidence='' fixed=0 dropped=0 pr='' settled show title='' label=''
  [ $# -ge 1 ] || refuse "close needs an id"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence) evidence=${2-}; shift ;;
      --fixed) fixed=1 ;;
      --dropped) dropped=1 ;;
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
  [ "$dropped" = 0 ] || [ "$fixed" = 0 ] || refuse "--fixed and --dropped do not combine"
  [ "$dropped" = 0 ] || [ "${id%%-*}" = noticed ] || refuse "--dropped records a noticed item firstmate dropped; an idea waits for his pick"
  settled="Settled $TODAY: $evidence${pr:+ ($pr)}"
  [ "$fixed" = 0 ] || { settled="$settled Fixed by firstmate on its own."; label=fixed; }
  [ "$dropped" = 0 ] || { settled="$settled Dropped by firstmate on its own."; label=dropped; }
  lock_state
  show=$("$TASKS" show "$id" --full 2>/dev/null) || { echo "fm-noticed: could not read $id" >&2; exit 1; }
  title=$(shown_field "$show" title)
  append_body "$id" "$settled" || { echo "fm-noticed: could not record the evidence on $id" >&2; exit 1; }
  if [ "$(shown_field "$show" state)" != "done" ]; then
    "$TASKS" "done" "$id" >/dev/null || { echo "fm-noticed: could not close $id" >&2; exit 1; }
  fi
  # An urgent row he has not been told about yet stays for the drain.
  if ! grep -q "^$id${TAB}now$TAB" "$UNSEEN" 2>/dev/null; then
    drop_unseen "$id"
    case "$label" in
      fixed) add_unseen "$id" fixed "$title - $evidence ($pr)" ;;
      dropped) add_unseen "$id" dropped "$title - $evidence" ;;
    esac
  fi
  printf 'closed: %s\n' "$id"
}

cmd_waiting() {
  local id snapshot rows days title
  if [ "${1:-}" = --shown ]; then
    shift
    [ $# -ge 1 ] || refuse "waiting --shown needs at least one id"
    lock_state
    for id in "$@"; do
      [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "bad task id $id"
      grep -Fxq -- "$id" "$WAITING_SHOWN" 2>/dev/null || printf '%s\n' "$id" >> "$WAITING_SHOWN"
      printf 'shown: %s\n' "$id"
    done
    return 0
  fi
  [ $# -eq 0 ] || refuse "waiting takes no arguments, or --shown <id>..."
  snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input) \
    || { echo "fm-noticed: could not read the backlog snapshot" >&2; exit 1; }
  rows=$(printf '%s' "$snapshot" | jq -r '
    .backlog.records[]
    | select(.structured and .hold_bucket == "aged")
    | [.id, ((.hold_age_days // "?") | tostring), .title] | @tsv') \
    || { echo "fm-noticed: could not read the aged calls from the snapshot" >&2; exit 1; }
  [ -n "$rows" ] || return 0
  while IFS=$TAB read -r id days title; do
    grep -Fxq -- "$id" "$WAITING_SHOWN" 2>/dev/null && continue
    printf '%s\t%s\t%s\n' "$id" "$days" "$title"
  done <<< "$rows"
}

case "${1:-}" in
  file) shift; cmd_file "$@" ;;
  waiting) shift; cmd_waiting "$@" ;;
  close) shift; cmd_close "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  list) shift; cmd_list "$@" ;;
  unseen) shift; cmd_unseen "$@" ;;
  shown) shift; cmd_shown "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh owner <id> [arjun|fleet]
#        fm-tasks-axi.sh due <id> [YYYY-MM-DD|-]
#        fm-tasks-axi.sh batch <id> [<tag>|-]
#        fm-tasks-axi.sh archive-path
#        fm-tasks-axi.sh apply <file> [--check]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Owner (bin/fm-backlog-owner-lib.sh owns the record and its meaning): every
# row this command adds names who owns its next move, `arjun` or `fleet`, on
# an `Owner:` body line. `add` (and `create`) takes `--owner arjun|fleet`,
# which the wrapper consumes; without it a row gets the default for its kind
# (fleet), except `--kind captain`, which must name one and is refused
# otherwise. An `Owner:` line already in the given body counts as naming one.
# A `--kind captain` row owned by `arjun` is a step only the captain can take,
# so once `add` succeeds, the new or already-present row tasks-axi reports (the
# `task.id` of an `add --json` result, else its text `ok:` line), if
# open and carrying no hold, is held for him through bin/fm-captain-hold.sh
# hold, which re-checks it under the row's control lock, keeps it out of
# dispatch and puts it among his calls (fork patch,
# docs/fork-decisions/2026-11-20-captain-kind-rows-held-at-filing.md); a row
# that cannot be held fails the command with exit 1 after the add.
# `update` with `--body` or `--body-file` carries the row's recorded owner
# into a new body that names none, so rewriting a note never drops it; such
# an update names the row id first and refuses when the row cannot be read.
# The wrapper-only subcommand `owner <id>` prints the recorded owner (`-` when
# none), and `owner <id> arjun|fleet` records it, idempotently, under the same
# per-task control lock bin/fm-captain-hold.sh takes, waiting at most
# FM_TASKS_AXI_OWNER_LOCK_SECS (default 30) for it. A row held for the
# captain, including a hold whose date has passed, waits on him, so neither
# `owner <id> fleet` nor an update whose body names the fleet may record fleet
# on it: re-hold fleet work that comes back on a date as a `future` hold first.
# Every row read here is bounded like the lifecycle transitions' reads
# (FM_BACKLOG_ROW_TIMEOUT_SECS).
#
# Row shape (fork patch, docs/fork-decisions/2026-11-08-backlog-row-shape.md;
# bin/fm-backlog-row-lib.sh owns the hold kinds and the line formats):
# `hold` takes one of the four hold kinds, `--kind captain|external|future|
# parked`, and a date: a back-on date, `--until YYYY-MM-DD`, which for an
# external wait is its recheck date, and which a captain call may replace
# with a `Due:` date the row already records. A hold without a kind or a date
# is refused (a help read is not checked); a live captain call without
# `--until` goes through bin/fm-captain-hold.sh hold, which needs no date. `add`
# refuses a title that
# opens with a `[YYYY-MM-DD]` date, as does `update --title`. `add` also takes
# `--due YYYY-MM-DD`, the real deadline, and `--batch <tag>`, a group the
# captain moves together, which the wrapper consumes into `Due:` and `Batch:`
# body lines. `update` with a new body that names neither carries the row's
# recorded ones, as it carries the owner. The wrapper-only subcommands
# `due <id>` and `batch <id>` print the recorded value (`-` when none), and
# `due <id> YYYY-MM-DD|-` and `batch <id> <tag>|-` record or clear it under the
# same control lock as `owner`. Rows already in the backlog stay readable as
# they are.
#
# Handoff replies: after `done` (or `close`) and `rm` (or `delete`) succeed, the
# wrapper runs bin/fm-inbox.sh close-reply, which answers the row's handoff note
# (request id handoff:<id>) when it has no reply yet: done with the close's
# --pr/--report/--note, or removed with the reason `rm` takes as
# `--reason <text>`, which the wrapper consumes. A row no handoff filed is
# untouched, and the reply never changes the close's exit status or stdout.
# A caller whose close is not the work being done sets FM_HANDOFF_CLOSE_REPLY:
# `removed` answers as removed with the --note as the reason (the weekly prune
# drops rows through `done`), and `skip` writes nothing, leaving the reply to a
# person (bin/fm-inbox.sh unread resurfaces it). A help read writes nothing.
# Reply before closing when you have a fuller answer: a note keeps one reply.
#
# Done archive: tasks-axi never reads back the rows that markdown retention
# moved out of the backlog. The wrapper-only subcommand `archive-path` prints
# where this home's configured archive lives (bin/fm-backlog-transition-lib.sh
# fm_backlog_markdown_archive owns the resolution), whether or not it exists
# yet; it prints nothing when the backend keeps no markdown archive, and
# refuses when the backend configuration cannot be read. A `done` (or `close`)
# that tasks-axi refuses as NOT_FOUND, of a row that archive holds, prints
# `ok: <id> already done (archived)` (with `--json`, a result object whose
# `already` and `archived` are true) and exits 0, writing no handoff reply, so
# a caller that closes a row retention already moved reads it as closed.
#
# Apply: the wrapper-only subcommand `apply <file>` sets many rows' fields
# from one reviewed list, such as a sweep's corrections, as fields and never
# as body notes. <file> (relative to the caller's directory) holds a JSON
# array of rows; each names its `id` and at least one of:
#   "title": "<next action>"           through `update <id> --title`
#   "batch": "<tag>" or "-"            through `batch <id>`
#   "hold": {"kind": "future|parked|external", "until": "YYYY-MM-DD",
#            "reason": "<one line>"}   through `hold`; no parentheses
#   "hold": {"kind": "captain", "reason": "<one line>",
#            "until": "YYYY-MM-DD", "call": "reversible|arjun-only"}
#                                      through bin/fm-captain-hold.sh hold
#                                      --keep-choices; until and call optional
#   "ask": "<question>"                his call's question: beside a captain
#                                      hold it rides on that hold, alone it
#                                      goes through fm-captain-hold.sh choices
# Every field of every row is checked first against the row as stored (an
# open row, a valid title, tag, kind and date, an ask only on a captain
# hold), and one field it cannot set, or an unknown key, refuses the whole
# file with exit 2 before anything is written, naming each refusal on stderr.
# `--check` stops there and prints the plan. Otherwise the fields run in the
# order title, batch, hold, ask, each through the command that owns it, so its
# guards and locks hold; a row stops at its first failed field, and the
# command prints one `ok:` or `failed:` line per field and a summary, and
# exits 1 when any field failed. A rerun of the same file converges.
#
# Superseded-ruling guard (opt-in): when the home-private `config/captain-name`
# names the captain (one name per line; blank and `#` lines ignored), `hold`,
# including a park (`hold --kind parked`), refuses a `--reason` that cites a
# dated captain quote - the name followed by an ISO date, as in
# "Arjun 2026-09-30:" - older than the newest such quote on record for that
# task: its row (`show <id> --full`), its brief `<data>/<id>/brief.md`, and its
# handled steers `<state>/<id>.inbox/handled/*.msg`. A hold that re-cites an
# older ruling would quietly undo the newer one. Pass `--cite-older-quote` to
# hold on the older quote deliberately; the wrapper consumes the flag. A reason
# that cites no dated captain quote is not checked, and an absent or empty
# file turns the guard off, so a home without it is unaffected.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file;
#   - a `hold` whose reason cites a captain quote older than the newest one on
#     record for the task, without --cite-older-quote (see the guard above);
#   - an `add` of `--kind captain` that names no owner, an `--owner` value
#     other than arjun or fleet, `owner` on a row that does not exist,
#     fleet on a row held for the captain, a control lock not freed in time,
#     or an `update` with a new body whose row id is not first or whose row
#     cannot be read;
#   - a `hold` without one of the four kinds, or without a valid `--until`
#     date (a captain call: nor a recorded due date), a title that opens with a
#     date, an invalid `--due` date or
#     `--batch` tag (or a new body's `Batch:` line naming one that is not the
#     row's recorded tag), or `due`/`batch` on a row that does not exist.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-backlog-owner-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-owner-lib.sh"
# shellcheck source=bin/fm-backlog-row-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-row-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
CITE_OLDER_QUOTE=0
REASON=
reason_value_next=0
OWNER=
DUE=
DUE_GIVEN=0
BATCH=
BATCH_GIVEN=0
path_value_next=0
owner_value_next=0
row_value_next=
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  if [ "$owner_value_next" = 1 ]; then
    OWNER=$arg
    owner_value_next=0
    continue
  fi
  if [ "$reason_value_next" = 1 ]; then
    REASON=$arg
    reason_value_next=0
    continue
  fi
  case "$row_value_next" in
    due) DUE=$arg; row_value_next=; continue ;;
    batch) BATCH=$arg; row_value_next=; continue ;;
  esac
  case "$arg" in
    --due|--due=*|--batch|--batch=*)
      case "${1:-}" in
        add|create)
          case "$arg" in
            --due) DUE_GIVEN=1; row_value_next='due' ;;
            --due=*) DUE_GIVEN=1; DUE=${arg#--due=} ;;
            --batch) BATCH_GIVEN=1; row_value_next='batch' ;;
            --batch=*) BATCH_GIVEN=1; BATCH=${arg#--batch=} ;;
          esac
          ;;
        *) ARGS+=("$arg") ;;
      esac
      ;;
    --owner|--owner=*)
      case "${1:-}" in
        add|create)
          if [ "$arg" = --owner ]; then
            owner_value_next=1
          else
            OWNER=${arg#--owner=}
          fi
          ;;
        *) ARGS+=("$arg") ;;
      esac
      ;;
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --reason|--reason=*)
      case "${1:-}" in
        rm|delete)
          if [ "$arg" = --reason ]; then
            reason_value_next=1
          else
            REASON=${arg#--reason=}
          fi
          ;;
        *) ARGS+=("$arg") ;;
      esac
      ;;
    --cite-older-quote)
      if [ "${1:-}" = hold ]; then
        CITE_OLDER_QUOTE=1
      else
        ARGS+=("$arg")
      fi
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

[ "$owner_value_next" = 0 ] || fail "--owner needs a value: arjun or fleet"
[ "$reason_value_next" = 0 ] || fail "--reason needs a value"
if [ -n "$OWNER" ] && ! fm_backlog_owner_valid "$OWNER"; then
  fail "--owner must be arjun or fleet, not $OWNER"
fi
[ -z "$row_value_next" ] || fail "--$row_value_next needs a value"
[ "$DUE_GIVEN" = 0 ] || fm_backlog_date_valid "$DUE" || fail "--due must be a YYYY-MM-DD date: $DUE"
[ "$BATCH_GIVEN" = 0 ] || fm_backlog_batch_valid "$BATCH" \
  || fail "--batch: $FM_BACKLOG_BATCH_RULE: $BATCH"

# The value of the last <flag> in ARGS; fails when the flag is absent.
arg_value() {  # <flag>
  local flag=$1 i=0 value='' found=1
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$i]}" in
      "$flag") i=$((i + 1)); value=${ARGS[$i]:-}; found=0 ;;
      "$flag"=*) value=${ARGS[$i]#"$flag"=}; found=0 ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$value"
  return "$found"
}

# The body the caller passed with --body or --body-file, into GIVEN_BODY;
# fails when neither was passed.
GIVEN_BODY=
GIVEN_BODY_STDIN=0
given_body() {
  local text file have_text=1 have_file=1
  text=$(arg_value --body) && have_text=0
  file=$(arg_value --body-file) && have_file=0
  [ "$have_text" = 1 ] || [ "$have_file" = 1 ] || fail "pass --body or --body-file, not both"
  if [ "$have_text" = 0 ]; then
    GIVEN_BODY=$text
  elif [ "$have_file" = 0 ]; then
    if [ "$file" = - ]; then
      GIVEN_BODY=$(cat)
      GIVEN_BODY_STDIN=1
    else
      [ -f "$file" ] && [ -r "$file" ] || fail "cannot read --body-file $file"
      GIVEN_BODY=$(cat -- "$file")
    fi
  else
    return 1
  fi
}

# Replace the caller's --body/--body-file with a staged file holding <body>.
OWNER_BODY_FILE=
stage_body() {  # <body>
  local out=() i=0
  OWNER_BODY_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-body.XXXXXX") \
    || fail "cannot stage the row body"
  printf '%s' "$1" > "$OWNER_BODY_FILE" || fail "cannot stage the row body"
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$i]}" in
      --body|--body-file) i=$((i + 2)); continue ;;
      --body=*|--body-file=*) i=$((i + 1)); continue ;;
    esac
    out+=("${ARGS[$i]}")
    i=$((i + 1))
  done
  ARGS=(${out[@]+"${out[@]}"} --body-file "$OWNER_BODY_FILE")
}

# The current read of row <id> into SHOWN_ROW and its decoded body into
# SHOWN_BODY; fails when the row cannot be read.
SHOWN_ROW=
SHOWN_BODY=
shown_body() {  # <id>
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  SHOWN_ROW=$(fm_backlog_row_show "$data" "$1" --full 2>/dev/null) || return 1
  printf '%s\n' "$SHOWN_ROW" | grep -q '^code: NOT_FOUND$' && return 1
  SHOWN_BODY=$(fm_backlog_owner_shown_body "$SHOWN_ROW") || return 1
}

# Whether the row last read by shown_body is held for the captain. A hold past
# its date reads `held: no` but keeps its captain kind and stays his call.
shown_captain_hold() {
  printf '%s\n' "$SHOWN_ROW" | grep -q '^  hold_kind: captain$' \
    && ! printf '%s\n' "$SHOWN_ROW" | grep -q '^  state: done$'
}

refuse_fleet_on_captain_hold() {  # <id>
  fail "$1 is held for the captain, so it waits on him; answer the hold, or re-hold fleet work that comes back on a date with hold --kind future --until, before naming the fleet"
}

# The row-shape refusals described in the header, before anything runs.
guard_row_shape() {
  local kind until title i arg
  # A help read writes nothing, so it reaches tasks-axi unchecked.
  for arg in ${ARGS[@]+"${ARGS[@]}"}; do
    case "$arg" in -h|--help) return 0 ;; esac
  done
  case "${ARGS[0]:-}" in
    hold)
      kind=$(arg_value --kind) || kind=
      fm_backlog_hold_kind_valid "$kind" \
        || fail "a hold needs --kind captain (the captain's answer or hands), external (someone else must act), future (nothing until a date) or parked (someday)"
      until=$(arg_value --until) || until=
      if [ -n "$until" ]; then
        fm_backlog_date_valid "$until" || fail "--until must be a YYYY-MM-DD date: $until"
        return 0
      fi
      # No back-on date: a captain call stays live, so its recorded due date
      # is its date. Other kinds need --until, which is what lifts them.
      case "$kind" in
        captain)
          case "${ARGS[1]:-}" in
            ''|-*) ;;
            *)
              if shown_body "${ARGS[1]}" && [ -n "$(fm_backlog_row_field_of_body due "$SHOWN_BODY")" ]; then
                return 0
              fi
              ;;
          esac
          fail "a live captain call goes through bin/fm-captain-hold.sh hold, which needs no date; or pass --until YYYY-MM-DD for when it comes back"
          ;;
        external) fail "an external wait needs its recheck date: pass --until YYYY-MM-DD for when to check on it" ;;
        *) fail "a hold needs its back-on date: pass --until YYYY-MM-DD for when the row comes back" ;;
      esac
      ;;
    add|create)
      for i in 1 2; do
        title=${ARGS[$i]:-}
        case "$title" in -*) break ;; esac
        ! fm_backlog_title_dated "$title" \
          || fail "a title names the next action, not a date: drop the leading date and record it as the hold's --until or the row's --due"
      done
      ;;
    update|edit)
      if title=$(arg_value --title) && fm_backlog_title_dated "$title"; then
        fail "a title names the next action, not a date: drop the leading date and record it as the hold's --until or the row's due date"
      fi
      ;;
  esac
}

# Hold bin/fm-captain-hold.sh's per-task control lock for the rest of this
# command, bounded, so an owner rewrite never replays a body that a
# concurrent hold or answer has just changed.
task_lock() {  # <id>
  local secs=${FM_TASKS_AXI_OWNER_LOCK_SECS:-30}
  case "$secs" in ''|*[!0-9]*) secs=30 ;; esac
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  TASK_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait_max "$TASK_LOCK" "$secs" \
    || fail "the control lock for $1 was not freed within ${secs}s (a hold, answer, spawn, or merge on it is still running); retry once it finishes"
  trap 'fm_lock_release "$TASK_LOCK"' EXIT
}

# add/create of a captain-owned kind=captain row: hold it for him unless the
# row is closed or already carries a hold of any kind (see the header).
hold_added_captain_row() {  # <tasks-axi add output>
  local id kind arg title
  for arg in ${ARGS[@]+"${ARGS[@]}"}; do
    case "$arg" in -h|--help) return 0 ;; esac
  done
  kind=$(arg_value --kind) || kind=
  [ "$kind" = captain ] && [ "$OWNER" = arjun ] || return 0
  # The row tasks-axi reports it added, wherever the id sat or was minted:
  # `task.id` of an `add --json` result, else its text `ok:` line.
  id=$(printf '%s\n' "$1" | jq -r '.task.id // empty | strings' 2>/dev/null) || id=
  [ -n "$id" ] || id=$(printf '%s\n' "$1" | sed -n -e 's/^ok: added \([^ ]*\) .*/\1/p' -e 's/^ok: add \([^ ]*\) already exists.*/\1/p' | head -1)
  [ -n "$id" ] || { printf 'fm-tasks-axi: could not tell which row this add filed, so it was not held for the captain; hold it with bin/fm-captain-hold.sh hold before anything dispatches it\n' >&2; return 1; }
  shown_body "$id" || { printf 'fm-tasks-axi: %s was added but could not be read to hold it for the captain; hold it with bin/fm-captain-hold.sh hold before anything dispatches it\n' "$id" >&2; return 1; }
  # An idempotent add keeps the stored row, so judge the row as stored;
  # bin/fm-captain-hold.sh repeats this check under the row's control lock.
  printf '%s\n' "$SHOWN_ROW" | grep -q '^  state: done$' && return 0
  printf '%s\n' "$SHOWN_ROW" | grep -q '^  kind: captain$' || return 0
  [ "$(fm_backlog_owner_of_body "$SHOWN_BODY")" = arjun ] || return 0
  printf '%s\n' "$SHOWN_ROW" | grep -Eq '^  held: no$' || return 0
  [ "$(printf '%s\n' "$SHOWN_ROW" | grep -Ec '^  hold_(kind|reason|until): ("-"|-)$')" = 3 ] || return 0
  title=$(fm_backlog_owner_shown_body "$(printf '%s\n' "$SHOWN_ROW" | sed -n 's/^  title: /  body: /p' | head -1)") || title=$id
  FM_CAPTAIN_HOLD_IF_UNHELD_CAPTAIN_ROW=1 "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --kind arjun-only \
    --reason "only you can take this step: ${title:-$id}" >/dev/null \
    || { printf 'fm-tasks-axi: %s was added but could not be held for the captain; hold it with bin/fm-captain-hold.sh hold before anything dispatches it\n' "$id" >&2; return 1; }
}

# A new body's own Batch: tag is written like `--batch`, so a bare legacy slug
# is refused unless it is the tag the row already records.
refuse_body_batch() {  # <new-body> <recorded-tag-or-empty>
  local named
  named=$(fm_backlog_row_field_of_body batch "$1")
  [ -z "$named" ] || [ "$named" = "$2" ] || fm_backlog_batch_valid "$named" \
    || fail "the body's Batch: line: $FM_BACKLOG_BATCH_RULE: $named"
}

# add/create: name the owner at filing (see the header), and record any
# --due and --batch lines above it.
prepare_add_owner() {
  local kind recorded body
  kind=$(arg_value --kind) || kind=
  if given_body; then :; else GIVEN_BODY=; fi
  if [ -z "$OWNER" ]; then
    recorded=$(fm_backlog_owner_of_body "$GIVEN_BODY")
    if [ -n "$recorded" ]; then
      OWNER=$recorded
    elif ! OWNER=$(fm_backlog_owner_default "$kind"); then
      fail "a kind=captain row must name its owner: --owner arjun when only the captain can move it, --owner fleet when the fleet does the work and reports to him"
    fi
  fi
  body=$GIVEN_BODY
  [ "$BATCH_GIVEN" = 1 ] || refuse_body_batch "$body" ''
  [ "$DUE_GIVEN" = 0 ] || body=$(fm_backlog_row_field_body_with due "$body" "$DUE")
  [ "$BATCH_GIVEN" = 0 ] || body=$(fm_backlog_row_field_body_with batch "$body" "$BATCH")
  stage_body "$(fm_backlog_owner_body_with "$body" "$OWNER")"
}

# update with a new body: keep the recorded owner, due date and batch tag when
# the new body names none.
prepare_update_owner() {
  local id=${ARGS[1]:-} named recorded='' body field value carried=0
  given_body || return 0
  named=$(fm_backlog_owner_of_body "$GIVEN_BODY")
  body=$GIVEN_BODY
  case "$id" in
    ''|-*) fail "name the row id right after update, so its owner, due date and batch tag can be checked and carried into the new body" ;;
  esac
  shown_body "$id" || fail "cannot read $id to check and carry its owner, due date and batch tag into the new body"
  [ "$named" != fleet ] || ! shown_captain_hold || refuse_fleet_on_captain_hold "$id"
  refuse_body_batch "$body" "$(fm_backlog_row_field_of_body batch "$SHOWN_BODY")"
  [ -n "$named" ] || recorded=$(fm_backlog_owner_of_body "$SHOWN_BODY")
  for field in due batch; do
    [ -z "$(fm_backlog_row_field_of_body "$field" "$body")" ] || continue
    value=$(fm_backlog_row_field_of_body "$field" "$SHOWN_BODY")
    [ -n "$value" ] || continue
    body=$(fm_backlog_row_field_body_with "$field" "$body" "$value")
    carried=1
  done
  if [ -z "$recorded" ] && [ "$carried" = 1 ]; then
    recorded=$(fm_backlog_owner_of_body "$body")
  fi
  if [ -n "$recorded" ]; then
    stage_body "$(fm_backlog_owner_body_with "$body" "$recorded")"
  elif [ "$GIVEN_BODY_STDIN" = 1 ] || [ "$carried" = 1 ]; then
    # Standard input is already read, so hand tasks-axi the body as a file.
    stage_body "$body"
  fi
}

# The wrapper-only `owner <id> [arjun|fleet]` subcommand.
command_owner() {
  local id=${ARGS[1]:-} want=${ARGS[2]:-} recorded
  case "$id" in ''|-*) fail "usage: owner <id> [arjun|fleet]" ;; esac
  [ "${#ARGS[@]}" -le 3 ] || fail "usage: owner <id> [arjun|fleet]"
  if [ -n "$want" ]; then
    fm_backlog_owner_valid "$want" || fail "owner must be arjun or fleet, not $want"
    task_lock "$id"
  fi
  shown_body "$id" || fail "no backlog row $id in this home"
  recorded=$(fm_backlog_owner_of_body "$SHOWN_BODY")
  if [ -z "$want" ]; then
    printf '%s\n' "${recorded:--}"
    return 0
  fi
  [ "$want" != fleet ] || ! shown_captain_hold || refuse_fleet_on_captain_hold "$id"
  if [ "$recorded" = "$want" ]; then
    printf 'ok: owner %s already %s\n' "$id" "$want"
    return 0
  fi
  ARGS=(update "$id")
  stage_body "$(fm_backlog_owner_body_with "$SHOWN_BODY" "$want")"
  if ! tasks-axi "${ARGS[@]}" >/dev/null; then
    rm -f -- "$OWNER_BODY_FILE"
    fail "could not record owner $want on $id"
  fi
  rm -f -- "$OWNER_BODY_FILE"
  printf 'ok: owner %s -> %s\n' "$id" "$want"
}

# The wrapper-only `due <id> [YYYY-MM-DD|-]` and `batch <id> [<tag>|-]`
# subcommands.
command_row_field() {  # <due|batch>
  local field=$1 id=${ARGS[1]:-} want=${ARGS[2]:-} recorded body owner
  case "$id" in ''|-*) fail "usage: $field <id> [value|-]" ;; esac
  [ "${#ARGS[@]}" -le 3 ] || fail "usage: $field <id> [value|-]"
  if [ -n "$want" ] && [ "$want" != - ]; then
    case "$field" in
      due) fm_backlog_date_valid "$want" || fail "a due date must be YYYY-MM-DD: $want" ;;
      batch) fm_backlog_batch_valid "$want" \
        || fail "$FM_BACKLOG_BATCH_RULE: $want" ;;
    esac
  fi
  [ -z "$want" ] || task_lock "$id"
  shown_body "$id" || fail "no backlog row $id in this home"
  recorded=$(fm_backlog_row_field_of_body "$field" "$SHOWN_BODY")
  if [ -z "$want" ]; then
    printf '%s\n' "${recorded:--}"
    return 0
  fi
  [ "$want" != - ] || want=
  if [ "$recorded" = "$want" ]; then
    printf 'ok: %s %s already %s\n' "$field" "$id" "${want:--}"
    return 0
  fi
  body=$(fm_backlog_row_field_body_with "$field" "$SHOWN_BODY" "$want")
  owner=$(fm_backlog_owner_of_body "$SHOWN_BODY")
  [ -z "$owner" ] || body=$(fm_backlog_owner_body_with "$body" "$owner")
  ARGS=(update "$id")
  stage_body "$body"
  if ! tasks-axi "${ARGS[@]}" >/dev/null; then
    rm -f -- "$OWNER_BODY_FILE"
    fail "could not record $field ${want:--} on $id"
  fi
  rm -f -- "$OWNER_BODY_FILE"
  printf 'ok: %s %s -> %s\n' "$field" "$id" "${want:--}"
}

# The wrapper-only `apply <file> [--check]` subcommand (see the header).
# The shape refusals of the whole file, one line each; nothing when it is sound.
# shellcheck disable=SC2016  # a jq program, expanded by jq
APPLY_SHAPE_JQ='
  def row_errors($n):
    if type != "object" then "row \($n): a row must be a JSON object"
    else
      ((keys - ["id", "title", "batch", "hold", "ask"])[] | "row \($n): unknown field \(.)"),
      (if (.id | type) != "string" or .id == "" then "row \($n): id must be a non-empty string" else empty end),
      (if (keys - ["id"]) == [] then "row \($n): names no field to set" else empty end),
      (("title", "batch", "ask") as $k
        | select(has($k) and (.[$k] | type) != "string") | "row \($n): \($k) must be a string"),
      (if has("hold") then
         if (.hold | type) != "object" then "row \($n): hold must be a JSON object"
         else
           ((.hold | keys - ["kind", "until", "reason", "call"])[] | "row \($n): unknown hold field \(.)"),
           (("kind", "until", "reason", "call") as $k
             | select((.hold | has($k)) and (.hold[$k] | type) != "string") | "row \($n): hold.\($k) must be a string")
         end
       else empty end),
      (if [.. | strings | select(test("[\r\n  ]"))] != [] then "row \($n): a value spans more than one line" else empty end)
    end;
  if length != 1 or (.[0] | type) != "array" then "the file must hold one JSON array of rows"
  elif (.[0] | length) == 0 then "the file holds no rows"
  else
    .[0]
    | (to_entries[] | .key as $i | .value | row_errors($i + 1)),
      ([.[] | objects | .id | strings] | group_by(.) | map(select(length > 1) | .[0])[] | "id \(.) is named by more than one row")
  end'

# One field of row <index>: prints `+<value>` when the row sets it, nothing
# when it does not.
apply_get() {  # <file> <index> <jq path, such as .title or .hold.kind>
  jq -r --argjson i "$2" ".[\$i] | ($3) as \$v | if \$v == null then empty else \"+\" + \$v end" "$1"
}

# Run a backlog command as the caller did, from the caller's directory with
# the caller's home, for one field of `apply`; prints its output on failure.
apply_run() {  # <command> [args...]
  local out
  if out=$(cd "$CALLER_DIR" && "$@" 2>&1); then
    return 0
  fi
  printf '%s' "$out" | tr '\n' ' '
  return 1
}

# The kind, reversible or arjun-only, that the captain hold of the row last read
# by shown_body records on its reason (bin/fm-captain-hold.sh owns that
# prefix); fails when the row has no captain hold or its reason no kind.
shown_call_kind() {
  local kind
  printf '%s\n' "$SHOWN_ROW" | grep -q '^  hold_kind: captain$' || return 1
  kind=$(printf '%s\n' "$SHOWN_ROW" | fm_hold_reason_decode_stream 2>/dev/null \
    | grep -E '^  hold_reason: "?\[(reversible|arjun-only)[];]' | head -1 | grep -oE 'reversible|arjun-only' | head -1)
  [ -n "$kind" ] && printf '%s\n' "$kind"
}

# Whether tasks-axi takes <title> as a title, asked of tasks-axi itself on a
# scratch markdown backlog so its own title rules decide; prints its refusal.
apply_title_probe() {  # <title>
  local probe=$APPLY_SCRATCH/probe out
  if [ ! -f "$probe/backlog.md" ]; then
    if ! { mkdir -p "$probe" && printf '## In flight\n\n## Queued\n\n## Done\n' > "$probe/backlog.md" \
      && (cd "$probe" && unset TASKS_AXI_FILE TASKS_AXI_BACKEND \
        && tasks-axi add title-probe probe --backend markdown --file "$probe/backlog.md" >/dev/null); }; then
      printf 'the title check could not start'
      return 1
    fi
  fi
  out=$(cd "$probe" && unset TASKS_AXI_FILE TASKS_AXI_BACKEND \
    && tasks-axi update title-probe --title="$1" --backend markdown --file "$probe/backlog.md" 2>&1) && return 0
  printf '%s' "$out" | sed -n 's/^error: //p' | head -1
  return 1
}

# One refused field of the row command_apply is checking (its n and id).
apply_refuse() {  # <why>
  printf 'refused: row %s (%s): %s\n' "$n" "$id" "$*" >&2
  refused=$((refused + 1))
}

command_apply() {
  local file=${ARGS[1]:-} check=0 shape count i n id title batch ask hold kind until reason call out
  local has_title has_batch has_ask has_hold refused=0 changes=0 failed=0 field status
  local -a plan=() row_ids=() cargs=()
  case "${ARGS[2]:-}" in
    '') ;;
    --check) check=1 ;;
    *) fail "usage: apply <file> [--check]" ;;
  esac
  [ "${#ARGS[@]}" -le 3 ] || fail "usage: apply <file> [--check]"
  case "$file" in ''|-*) fail "usage: apply <file> [--check]" ;; esac
  file=$(absolute_from_caller "$file")
  [ -f "$file" ] && [ -r "$file" ] || fail "cannot read the apply file $file"
  command -v jq >/dev/null 2>&1 || fail "apply needs jq on PATH"
  # Check and write from one copy, so an edit to the list mid-run applies
  # nothing unchecked; the scratch backlog beside it is apply_title_probe's.
  APPLY_SCRATCH=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-tasks-axi-apply.XXXXXX") || fail "cannot stage the apply file"
  trap 'rm -rf -- "$APPLY_SCRATCH"' EXIT
  cp -- "$file" "$APPLY_SCRATCH/list.json" || fail "cannot stage the apply file $file"
  local source=$file
  file=$APPLY_SCRATCH/list.json
  shape=$(jq -rs "$APPLY_SHAPE_JQ" "$file" 2>&1) || fail "the apply file is not JSON: $(printf '%s' "$shape" | head -1)"
  if [ -n "$shape" ]; then
    printf '%s\n' "$shape" | sed 's/^/refused: /' >&2
    fail "apply refused the file; nothing was changed"
  fi
  count=$(jq 'length' "$file")
  # Every field each row sets, checked against the row as stored, before any write.
  i=0
  while [ "$i" -lt "$count" ]; do
    n=$((i + 1))
    id=$(apply_get "$file" "$i" .id); id=${id#+}
    row_ids+=("$id")
    title=$(apply_get "$file" "$i" .title); has_title=${title:0:1}; title=${title#+}
    batch=$(apply_get "$file" "$i" .batch); has_batch=${batch:0:1}; batch=${batch#+}
    ask=$(apply_get "$file" "$i" .ask); has_ask=${ask:0:1}; ask=${ask#+}
    hold=$(jq -r --argjson i "$i" '.[$i] | has("hold")' "$file")
    kind=$(apply_get "$file" "$i" .hold.kind); kind=${kind#+}
    until=$(apply_get "$file" "$i" .hold.until); until=${until#+}
    reason=$(apply_get "$file" "$i" .hold.reason); reason=${reason#+}
    call=$(apply_get "$file" "$i" .hold.call); call=${call#+}
    has_hold=0
    [ "$hold" != true ] || has_hold=1
    if ! [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      apply_refuse "the id is not slug-shaped"
    elif ! shown_body "$id"; then
      apply_refuse "no backlog row $id in this home"
    elif printf '%s\n' "$SHOWN_ROW" | grep -q '^  state: done$'; then
      apply_refuse "the row is closed"
    elif printf '%s\n' "$SHOWN_ROW" | grep -q '^  kind: public-followup$'; then
      apply_refuse "a public-followup row changes only through tasks-axi public-followup"
    else
      if [ "$has_title" = + ]; then
        if fm_backlog_title_dated "$title"; then apply_refuse "a title names the next action, not a date"
        elif ! out=$(apply_title_probe "$title"); then
          apply_refuse "tasks-axi refuses this title: $out"
        else plan+=("$id title: $title"); fi
      fi
      if [ "$has_batch" = + ]; then
        if [ "$batch" = - ] || fm_backlog_batch_valid "$batch"; then plan+=("$id batch: $batch")
        else apply_refuse "$FM_BACKLOG_BATCH_RULE: $batch"; fi
      fi
      if [ "$has_hold" = 1 ]; then
        if ! fm_backlog_hold_kind_valid "$kind"; then
          apply_refuse "hold.kind must be captain, external, future or parked"
        elif [ -z "$reason" ]; then
          apply_refuse "hold.reason is empty"
        elif [ -n "$until" ] && ! fm_backlog_date_valid "$until"; then
          apply_refuse "hold.until must be a YYYY-MM-DD date: $until"
        elif [ "$kind" != captain ] && [ -z "$until" ]; then
          apply_refuse "a $kind hold needs hold.until, the date that lifts it"
        elif [ "$kind" != captain ] && [ -n "$call" ]; then
          apply_refuse "hold.call classifies a captain hold only"
        elif [ "$kind" != captain ] && [ "$has_ask" = + ]; then
          apply_refuse "an ask rides on a captain hold, not a $kind one"
        elif [ "$kind" != captain ] && [[ "$reason" == *[\(\)]* ]]; then
          apply_refuse "tasks-axi refuses parentheses in a $kind hold reason"
        elif [ -n "$call" ] && [ "$call" != reversible ] && [ "$call" != arjun-only ]; then
          apply_refuse "hold.call must be reversible or arjun-only: $call"
        elif [ "$kind" = captain ] && [[ "$reason" =~ ^\[(reversible|arjun-only)[]\;] ]]; then
          apply_refuse "hold.reason must not begin with a kind prefix; give hold.call instead"
        else
          plan+=("$id hold: $kind${until:+ until $until}${call:+ ($call)} - $reason")
        fi
      fi
      if [ "$has_ask" = + ]; then
        if [ -z "$ask" ]; then
          apply_refuse "ask is empty"
        elif [[ "$ask" == *[\]\;]* ]] || [ "$(printf '%s' "$ask" | wc -c | tr -d ' ')" -gt 200 ]; then
          apply_refuse "ask must be at most 200 bytes, with no ] or ;"
        elif [ "$has_hold" = 0 ] && ! { printf '%s\n' "$SHOWN_ROW" | grep -q '^  hold_kind: captain$' \
            && printf '%s\n' "$SHOWN_ROW" | grep -q '^  held: yes$'; }; then
          apply_refuse "an ask needs a captain hold: the row is not held for the captain, so give it a hold of kind captain"
        elif [ "$has_hold" = 0 ] && ! shown_call_kind >/dev/null; then
          apply_refuse "an ask rides on the call's kind, which this row's hold does not record: give it a hold of kind captain with hold.call"
        elif [ "$has_hold" = 1 ] && [ "$kind" = captain ] && [ -z "$call" ] && ! shown_call_kind >/dev/null; then
          apply_refuse "an ask rides on the call's kind: give hold.call reversible or arjun-only"
        elif [ "$has_hold" = 0 ] || [ "$kind" = captain ]; then
          plan+=("$id ask: $ask")
        fi
      fi
    fi
    i=$((i + 1))
  done
  [ "$refused" = 0 ] || fail "apply refused $refused field(s) of $source; nothing was changed"
  if [ "$check" = 1 ]; then
    [ "${#plan[@]}" = 0 ] || printf 'plan: %s\n' "${plan[@]}"
    printf 'apply: %s rows, %s changes checked; nothing was changed\n' "$count" "${#plan[@]}"
    return 0
  fi
  # Each field through the command that owns it, so its own guards and locks
  # hold; a row's later fields stop at its first failure.
  i=0
  while [ "$i" -lt "$count" ]; do
    id=${row_ids[$i]}
    title=$(apply_get "$file" "$i" .title); has_title=${title:0:1}; title=${title#+}
    batch=$(apply_get "$file" "$i" .batch); has_batch=${batch:0:1}; batch=${batch#+}
    ask=$(apply_get "$file" "$i" .ask); has_ask=${ask:0:1}; ask=${ask#+}
    kind=$(apply_get "$file" "$i" .hold.kind); kind=${kind#+}
    until=$(apply_get "$file" "$i" .hold.until); until=${until#+}
    reason=$(apply_get "$file" "$i" .hold.reason); reason=${reason#+}
    call=$(apply_get "$file" "$i" .hold.call); call=${call#+}
    for field in title batch hold ask; do
      status=0
      case "$field" in
        title)
          [ "$has_title" = + ] || continue
          # The = form keeps a value such as --help a value.
          out=$(apply_run "$SCRIPT_DIR/fm-tasks-axi.sh" update "$id" --title="$title") || status=1
          ;;
        batch)
          [ "$has_batch" = + ] || continue
          out=$(apply_run "$SCRIPT_DIR/fm-tasks-axi.sh" batch "$id" "$batch") || status=1
          ;;
        hold)
          [ -n "$kind" ] || continue
          if [ "$kind" = captain ]; then
            cargs=(hold "$id" --reason "$reason" --keep-choices)
            [ -z "$until" ] || cargs+=(--until "$until")
            [ -z "$call" ] || cargs+=(--kind "$call")
            [ "$has_ask" != + ] || cargs+=(--ask "$ask")
            out=$(apply_run "$SCRIPT_DIR/fm-captain-hold.sh" "${cargs[@]}") || status=1
          else
            out=$(apply_run "$SCRIPT_DIR/fm-tasks-axi.sh" hold "$id" --kind "$kind" --until "$until" --reason="$reason") \
              || status=1
          fi
          ;;
        ask)
          # An ask beside a captain hold rode on that hold.
          [ "$has_ask" = + ] && [ -z "$kind" ] || continue
          out=$(apply_run "$SCRIPT_DIR/fm-captain-hold.sh" choices "$id" --ask "$ask") || status=1
          ;;
      esac
      if [ "$status" = 0 ]; then
        changes=$((changes + 1))
        printf 'ok: apply %s %s\n' "$id" "$field"
      else
        failed=$((failed + 1))
        printf 'failed: apply %s %s: %s\n' "$id" "$field" "$out"
        break
      fi
    done
    i=$((i + 1))
  done
  printf 'apply: %s rows, %s changes, %s failed\n' "$count" "$changes" "$failed"
  [ "$failed" = 0 ] || return 1
}

# The superseded-ruling guard described in the header. Each helper prints
# nothing when it finds no dated captain quote.
captain_names() {
  [ -f "$CONFIG/captain-name" ] || return 0
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' "$CONFIG/captain-name"
}

# Newest date that follows a configured captain name in stdin, as YYYY-MM-DD.
newest_captain_quote() {  # <names, newline-separated>
  local name_list=$1
  NAMES=$name_list perl -ne '
    BEGIN {
      my @n = grep { length } split /\n/, $ENV{NAMES};
      $re = join "|", map { quotemeta } @n;
    }
    while (/(?<![[:alnum:]_])(?:$re)(?![[:alnum:]_])[\s,:(]*(?:on\s+)?(\d{4}-\d{2}-\d{2})(?!\d)/g) {
      $max = $1 if !defined($max) || $1 gt $max;
    }
    END { print $max if defined $max }
  '
}

guard_superseded_quote() {
  local names reason='' id='' cited newest='' source='' found file i=1
  [ "${ARGS[0]:-}" = hold ] || return 0
  [ "$CITE_OLDER_QUOTE" = 0 ] || return 0
  names=$(captain_names)
  [ -n "$names" ] || return 0
  case "${ARGS[1]:-}" in
    ''|-*) return 0 ;;
    */*|.|..) return 0 ;;
  esac
  id=${ARGS[1]}
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$i]}" in
      --reason) i=$((i + 1)); reason=${ARGS[$i]:-} ;;
      --reason=*) reason=${ARGS[$i]#--reason=} ;;
    esac
    i=$((i + 1))
  done
  cited=$(printf '%s\n' "$reason" | newest_captain_quote "$names")
  [ -n "$cited" ] || return 0

  found=$( (cd "$FM_BACKLOG_AXI_ROOT" && tasks-axi show "$id" --full 2>/dev/null) \
    | fm_hold_reason_decode_stream 2>/dev/null | newest_captain_quote "$names")
  if [ -n "$found" ]; then
    newest=$found
    source="its backlog row"
  fi
  for file in "$DATA/$id/brief.md" "$STATE/$id.inbox/handled/"*.msg; do
    [ -f "$file" ] || continue
    found=$(newest_captain_quote "$names" < "$file")
    if [ -n "$found" ] && { [ -z "$newest" ] || [[ "$found" > "$newest" ]]; }; then
      newest=$found
      source=$file
    fi
  done
  if [ -n "$newest" ] && [[ "$cited" < "$newest" ]]; then
    fail "the hold reason for $id cites a captain quote dated $cited, but the newest dated captain quote on record for it is $newest (in $source); cite the newer ruling, or pass --cite-older-quote if the older one deliberately stands"
  fi
}

# After a successful done/close or rm/delete, answer the row's handoff note
# through bin/fm-inbox.sh close-reply, which owns the reply and does nothing
# for a row no handoff filed. The close already landed, so a failure here only
# warns on stderr and never changes the exit status or stdout (--json stays
# parseable).
# The row a close or removal names, into CLOSE_ID, and the close's links and
# note into CLOSE_FLAGS and CLOSE_NOTE; fails for a help read.
CLOSE_ID=
CLOSE_NOTE=
CLOSE_FLAGS=()
close_args() {
  local arg i=1
  CLOSE_ID=
  CLOSE_NOTE=
  CLOSE_FLAGS=()
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    arg=${ARGS[$i]}
    case "$arg" in
      --note) CLOSE_NOTE=${ARGS[$((i + 1))]:-}; CLOSE_FLAGS+=("$arg" "$CLOSE_NOTE"); i=$((i + 1)) ;;
      --note=*) CLOSE_NOTE=${arg#--note=}; CLOSE_FLAGS+=("$arg") ;;
      --pr|--report) CLOSE_FLAGS+=("$arg" "${ARGS[$((i + 1))]:-}"); i=$((i + 1)) ;;
      --pr=*|--report=*) CLOSE_FLAGS+=("$arg") ;;
      --keep) i=$((i + 1)) ;;
      -h|--help) return 1 ;;
      -*) ;;
      *) [ -n "$CLOSE_ID" ] || CLOSE_ID=$arg ;;
    esac
    i=$((i + 1))
  done
}

# A done or close that tasks-axi refused as NOT_FOUND (<its output>) of a row
# the Done archive holds: report it already done, in the caller's format, and
# succeed. Fails, printing nothing, for any other refusal.
archived_close() {  # <tasks-axi output>
  local archive arg
  close_args || return 1
  [ -n "$CLOSE_ID" ] || return 1
  printf '%s\n' "$1" | grep -qx 'code: NOT_FOUND' || return 1
  archive=$(fm_backlog_markdown_archive "$DATA" 2>/dev/null) && [ -f "$archive" ] || return 1
  ID=$CLOSE_ID awk 'index($0, "- [x] " ENVIRON["ID"] " - ") == 1 { found = 1; exit } END { exit !found }' "$archive" \
    || return 1
  for arg in "${ARGS[@]}"; do
    if [ "$arg" = --json ]; then
      jq -n --arg id "$CLOSE_ID" '{ok: true, action: "done", already: true, archived: true, task: {id: $id, state: "done"}}'
      return
    fi
  done
  printf 'ok: %s already done (archived)\n' "$CLOSE_ID"
}

close_reply() {  # <verb>
  local verb=$1 id how="done" note
  local -a flags=()
  [ "${FM_HANDOFF_CLOSE_REPLY:-}" != skip ] || return 0
  close_args || return 0
  id=$CLOSE_ID
  note=$CLOSE_NOTE
  flags=(${CLOSE_FLAGS[@]+"${CLOSE_FLAGS[@]}"})
  [ -n "$id" ] || return 0
  case "$verb" in rm|delete) how=removed; flags=(--reason "$REASON") ;; esac
  [ "${FM_HANDOFF_CLOSE_REPLY:-}" != removed ] || { how=removed; flags=(--reason "${REASON:-$note}"); }
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-inbox.sh" close-reply "$id" "$how" ${flags[@]+"${flags[@]}"} >&2 \
    || printf 'fm-tasks-axi: %s %s landed, but its handoff reply was not written; answer it with bin/fm-inbox.sh reply\n' "$verb" "$id" >&2
  return 0
}

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

guard_row_shape
guard_superseded_quote

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
  owner)
    command_owner
    exit $?
    ;;
  due|batch)
    command_row_field "$1"
    exit $?
    ;;
  apply)
    command_apply
    exit $?
    ;;
  archive-path)
    [ "$#" -eq 1 ] || fail "archive-path takes no arguments"
    archive_status=0
    archive=$(fm_backlog_markdown_archive "$DATA") || archive_status=$?
    case "$archive_status" in
      0) printf '%s\n' "$archive" ;;
      1) ;;
      *) fail "the Done archive of $DATA cannot be resolved" ;;
    esac
    exit 0
    ;;
  add|create)
    prepare_add_owner
    ;;
  update|edit)
    prepare_update_owner
    ;;
esac
if [ -n "$OWNER_BODY_FILE" ]; then
  status=0
  case "${1:-}" in
    add|create)
      # Captured, then printed as is, so the filing hold knows the row's id.
      added=$(tasks-axi ${ARGS[@]+"${ARGS[@]}"}) || status=$?
      [ -z "$added" ] || printf '%s\n' "$added"
      ;;
    *) tasks-axi ${ARGS[@]+"${ARGS[@]}"} || status=$? ;;
  esac
  rm -f -- "$OWNER_BODY_FILE"
  case "${1:-}" in add|create) [ "$status" -ne 0 ] || hold_added_captain_row "$added" || status=1 ;; esac
  exit "$status"
fi
case "${1:-}" in
  done|close)
    # Captured, so a refusal of a row retention already archived reads as done.
    status=0
    closed=$(tasks-axi ${ARGS[@]+"${ARGS[@]}"}) || status=$?
    if [ "$status" -ne 0 ] && archived_close "$closed"; then
      exit 0
    fi
    [ -z "$closed" ] || printf '%s\n' "$closed"
    [ "$status" -eq 0 ] && close_reply "$1"
    exit "$status"
    ;;
  rm|delete)
    status=0
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} || status=$?
    [ "$status" -eq 0 ] && close_reply "$1"
    exit "$status"
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}

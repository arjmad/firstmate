#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh owner <id> [arjun|fleet]
#        fm-tasks-axi.sh due <id> [YYYY-MM-DD|-]
#        fm-tasks-axi.sh batch <id> [<tag>|-]
#        fm-tasks-axi.sh archive-path
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
# is refused (a help read is not checked); a new captain call without
# `--until` goes through bin/fm-captain-hold.sh hold, which records its due
# date. `add` refuses a title that
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
# Done archive: tasks-axi never reads back the rows that markdown retention
# moved out of the backlog. The wrapper-only subcommand `archive-path` prints
# where this home's configured archive lives (bin/fm-backlog-transition-lib.sh
# fm_backlog_markdown_archive owns the resolution), whether or not it exists
# yet; it prints nothing when the backend keeps no markdown archive, and
# refuses when the backend configuration cannot be read.
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
#     `--batch` tag, or `due`/`batch` on a row that does not exist.
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
if [ -n "$OWNER" ] && ! fm_backlog_owner_valid "$OWNER"; then
  fail "--owner must be arjun or fleet, not $OWNER"
fi
[ -z "$row_value_next" ] || fail "--$row_value_next needs a value"
[ "$DUE_GIVEN" = 0 ] || fm_backlog_date_valid "$DUE" || fail "--due must be a YYYY-MM-DD date: $DUE"
[ "$BATCH_GIVEN" = 0 ] || fm_backlog_batch_valid "$BATCH" \
  || fail "--batch must be a lowercase tag of letters, digits and dashes, at most 40 characters: $BATCH"

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
          fail "a captain call needs a date: hold it through bin/fm-captain-hold.sh hold, which gives a new call a due date, or pass --until YYYY-MM-DD"
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
        || fail "a batch tag is lowercase letters, digits and dashes, at most 40 characters: $want" ;;
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
  tasks-axi ${ARGS[@]+"${ARGS[@]}"} || status=$?
  rm -f -- "$OWNER_BODY_FILE"
  exit "$status"
fi
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}

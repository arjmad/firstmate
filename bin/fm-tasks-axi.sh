#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
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
#     record for the task, without --cite-older-quote (see the guard above).
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
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
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

# The superseded-ruling guard described in the header. Each helper prints
# nothing when it finds no dated captain quote.
captain_names() {
  [ -f "$CONFIG/captain-name" ] || return 0
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' "$CONFIG/captain-name"
}

# Newest date that follows a configured captain name in stdin, as YYYY-MM-DD.
newest_captain_quote() {  # <names, newline-separated>
  local names=$1
  NAMES=$names perl -ne '
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

guard_superseded_quote

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}

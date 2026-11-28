#!/usr/bin/env bash
# fm-asks.sh - the asks firstmate has open with people outside the fleet:
# list them with their age, and settle one when its backlog row closes.
#
# Usage: fm-asks.sh list [sapna|sunita] [--json]
#        fm-asks.sh settle <row-id> done|removed [--pr <url>] [--report <path>]
#               [--note <text>] [--reason <text>] [--asked <value>] [--title <text>]
#        fm-asks.sh --help
#
# Fork patch (docs/fork-decisions/2026-11-28-asks-to-outside-people.md, cap-23,
# Arjun 2026-11-25: "build"). A backlog row that waits on an ask to Sapna or
# Sunita carries one `Asked: <person> YYYY-MM-DD [<ref>]` body line
# (bin/fm-backlog-row-lib.sh owns the line; `fm-tasks-axi.sh asked <id>
# <person> [<ref>]` records it with today's date). The ask itself lives where
# that person's side reads it:
#   sapna   an envelope firstmate left Nova with the fleet-handoff skill's
#           `fm-handoff.sh to-nova --item <row-id>`; <ref> is its id.
#   sunita  Arjun's list for Sunita, the home-private data/sunita-list.md;
#           <ref> is the list's item. Nothing is ever sent to Sunita.
#
# `list` prints every open row (queued or in flight, held or not) that carries
# an `Asked:` line, oldest ask first, one tab-separated line each:
#   <row-id> <person> <age>d <asked-date> <ref or -> <title>
# where <age> is whole days from the asked date to today (UTC). A person
# narrows it to that person's asks; `--json` prints the same rows as a JSON
# array of {id, person, asked, age_days, ref, title}. Firstmate runs it here
# or as `fm-tasks-axi.sh list --asked [<person>]`, which is also how Nova reads
# Sapna's asks: the fleet-handoff skill's read-only `fm-handoff.sh backlog list
# --asked sapna`. A row the list cannot read is named on stderr and the
# command exits 1 after printing the rest.
#
# `settle` is what a close does for such a row, inside the fleet only.
# bin/fm-tasks-axi.sh runs it after a successful done/close or rm/delete (with
# the close's links or rm's reason, and the row's `Asked:` value and title as
# read just before the close), and the teardown close runs it through
# bin/fm-backlog-transition-lib.sh. A row with no `Asked:` line is a silent
# no-op. For sapna with an envelope id, it reads that envelope with
# `fm-handoff.sh sent <ref>`: already reported (`replied`) needs nothing, and
# otherwise it sends Nova the settlement the fleet-handoff skill's
# references/status-and-gotchas.md "Settled another way" names,
# `fm-handoff.sh to-nova "Settled: <title>" --kind reply --reply-to <ref>
# --item <row-id> --domain sapna --ask "<outcome>. Settle <ref> ...`, so Nova
# drops the ask the same turn. A sapna ask with no envelope id, an envelope
# the script cannot find, or a failed send prints a line saying Nova was not
# told, and the command exits 1. For sunita it sends nothing anywhere: it
# prints the line naming the list item to strike. A settled ask is recorded
# under state/asks/<row-id>.settled with its `Asked:` value, so a replayed
# close never tells Nova twice, while a reopened row asked again (a new value)
# settles again. FM_HANDOFF_CLOSE_REPLY=skip (a forced teardown) settles
# nothing. bin/fm-captain-hold.sh runs it too when an answer closes a call.
#
# The fleet-handoff script is FM_ASKS_HANDOFF, else
# $HOME/code/skills/skills/fleet-handoff/scripts/fm-handoff.sh; it is given
# FM_HANDOFF_FM_HOME=<this home>. FM_ASKS_TODAY (YYYY-MM-DD) overrides today's
# date for tests.
#
# Exit status: 0 on success or nothing to do, 1 when a row could not be read
# or a settlement was not delivered, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"
HANDOFF="${FM_ASKS_HANDOFF:-$HOME/code/skills/skills/fleet-handoff/scripts/fm-handoff.sh}"
# shellcheck source=bin/fm-backlog-owner-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-owner-lib.sh"
# shellcheck source=bin/fm-backlog-row-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-row-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-asks: %s\n' "$*" >&2
  exit 2
}

today() {
  if [ -n "${FM_ASKS_TODAY:-}" ]; then
    printf '%s\n' "$FM_ASKS_TODAY"
  else
    date -u +%Y-%m-%d
  fi
}

# One row's `show --full` read into ROW and its decoded body into BODY; fails
# when it cannot be read.
ROW=
BODY=
read_row() {  # <id>
  ROW=$(FM_HOME="$FM_HOME" "$TASKS" show "$1" --full 2>/dev/null) || return 1
  printf '%s\n' "$ROW" | grep -q '^task:$' || return 1
  BODY=$(fm_backlog_owner_shown_body "$ROW") || return 1
}

row_title() {
  fm_backlog_owner_shown_body "$(printf '%s\n' "$ROW" | sed -n 's/^  title: /  body: /p' | head -1)"
}

# The open rows a listing names, `<id> <body-hint>` per line: hint is 1 when
# the listed body shows an `Asked:` line or was cut short, so only those rows
# are read in full.
candidate_ids() {
  local listing
  listing=$(FM_HOME="$FM_HOME" "$TASKS" list --fields body --limit 1000000 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk '
    /^tasks\[[0-9]+\]\{id,state,/ { rows = 1; next }
    rows && /^  / {
      split(substr($0, 3), f, ",")
      id = f[1]
      if (id ~ /^"[^"]*"$/) id = substr(id, 2, length(id) - 2)
      if (f[2] != "queued" && f[2] != "in_flight") next
      if ($0 ~ /Asked: / || $0 ~ /\(truncated, [0-9]+ chars total/) print id
      next
    }
    { rows = 0 }'
}

command_list() {
  local who='' json=0 id value person date ref title failed=0 rows
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      sapna|sunita) [ -z "$who" ] || die "list names one person"; who=$1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "usage: fm-asks.sh list [sapna|sunita] [--json]" ;;
    esac
    shift
  done
  local ids
  ids=$(candidate_ids) || { printf 'fm-asks: could not list this home'"'"'s backlog\n' >&2; exit 1; }
  rows=$(
    for id in $ids; do
      if ! read_row "$id"; then
        printf 'fm-asks: could not read %s\n' "$id" >&2
        printf '!\n'
        continue
      fi
      value=$(fm_backlog_row_field_of_body asked "$BODY")
      [ -n "$value" ] || continue
      read -r person date ref <<<"$value"
      [ -z "$who" ] || [ "$person" = "$who" ] || continue
      title=$(row_title) || title=$id
      jq -cn --arg id "$id" --arg person "$person" --arg asked "$date" --arg ref "$ref" --arg title "$title" \
        '{id: $id, person: $person, asked: $asked, ref: (if $ref == "" then null else $ref end), title: $title}'
    done
  )
  ! printf '%s\n' "$rows" | grep -qx '!' || failed=1
  rows=$(printf '%s\n' "$rows" | grep -vx '!' || true)
  printf '%s\n' "$rows" | jq -s --arg today "$(today)" '
    def day($d): $d | strptime("%Y-%m-%d") | mktime | . / 86400 | floor;
    map(select(. != null) | . + {age_days: (day($today) - day(.asked))})
    | sort_by(.asked, .id)' |
    if [ "$json" = 1 ]; then
      cat
    else
      jq -r 'if length == 0 then "no open asks" else .[] | [.id, .person, "\(.age_days)d", .asked, (.ref // "-"), .title] | @tsv end'
    fi
  return "$failed"
}

# The outcome line Nova reads: what the close did, in one sentence.
outcome_text() {  # <id> <title> <how> <pr> <report> <note> <reason>
  local id=$1 title=$2 how=$3 pr=$4 report=$5 note=$6 reason=$7 text
  if [ "$how" = "done" ]; then
    text="Firstmate closed backlog row $id ($title) on $(today) as done"
    [ -z "$pr" ] || text="$text; PR $pr"
    [ -z "$report" ] || text="$text; report $report"
    [ -z "$note" ] || text="$text; note: $note"
  else
    text="Firstmate took backlog row $id ($title) off its backlog on $(today) without doing it; reason: ${reason:-none recorded}"
  fi
  printf '%s' "$text"
}

command_settle() {
  local id=${1:-} how=${2:-} pr='' report='' note='' reason='' asked='' asked_given=0 title=''
  local person date ref marker state out reply_id text
  [ -n "$id" ] && [ -n "$how" ] || die "usage: fm-asks.sh settle <row-id> done|removed [flags]"
  case "$how" in done|removed) ;; *) die "settle takes done or removed, not $how" ;; esac
  case "$id" in -*|*/*|.*) die "not a row id: $id" ;; esac
  shift 2
  # Unknown close flags are skipped, as bin/fm-inbox.sh close-reply skips
  # them, so a caller can pass the close's own flags through.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr|--report|--note|--reason|--asked|--title)
        [ "$#" -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --pr) pr=$2 ;;
          --report) report=$2 ;;
          --note) note=$2 ;;
          --reason) reason=$2 ;;
          --asked) asked=$2; asked_given=1 ;;
          --title) title=$2 ;;
        esac
        shift 2 ;;
      --pr=*) pr=${1#*=}; shift ;;
      --report=*) report=${1#*=}; shift ;;
      --note=*) note=${1#*=}; shift ;;
      --reason=*) reason=${1#*=}; shift ;;
      *) shift ;;
    esac
  done
  [ "${FM_HANDOFF_CLOSE_REPLY:-}" != skip ] || return 0
  if [ "$asked_given" = 0 ]; then
    read_row "$id" || { printf 'fm-asks: %s closed, but its row could not be read to settle an ask\n' "$id" >&2; return 1; }
    asked=$(fm_backlog_row_field_of_body asked "$BODY")
    [ -n "$title" ] || title=$(row_title) || title=$id
  fi
  [ -n "$asked" ] || return 0
  [ -n "$title" ] || title=$id
  read -r person date ref <<<"$asked"
  marker="$STATE/asks/$id.settled"
  if [ -f "$marker" ] && [ "$(sed -n 2p "$marker")" = "asked=$asked" ]; then
    printf 'ask %s already settled: %s\n' "$id" "$(head -n 1 "$marker")"
    return 0
  fi
  case "$person" in
    sunita)
      printf 'ask %s to Sunita (asked %s) closed; nothing is sent outside the fleet. Strike %s on data/sunita-list.md.\n' \
        "$id" "$date" "$([ -n "$ref" ] && printf 'item %s' "$ref" || printf 'its item')"
      record_settled "$marker" "sunita list ${ref:--}; nothing sent"
      return 0
      ;;
    sapna) ;;
    *) printf 'fm-asks: %s names an unknown person %s; nothing settled\n' "$id" "$person" >&2; return 1 ;;
  esac
  if [ -z "$ref" ]; then
    printf 'fm-asks: ask %s to Sapna has no envelope id on its Asked: line, so Nova was not told; send the settlement by hand (fleet-handoff references/status-and-gotchas.md)\n' "$id" >&2
    return 1
  fi
  if [ ! -x "$HANDOFF" ]; then
    printf 'fm-asks: ask %s to Sapna closed, but %s is missing, so Nova was not told about envelope %s; send the settlement by hand\n' "$id" "$HANDOFF" "$ref" >&2
    return 1
  fi
  if ! out=$(FM_HANDOFF_FM_HOME="$FM_HOME" "$HANDOFF" sent "$ref" 2>&1); then
    printf 'fm-asks: ask %s to Sapna closed, but envelope %s could not be read, so Nova was not told: %s\n' "$id" "$ref" "$(printf '%s' "$out" | head -n 1)" >&2
    return 1
  fi
  state=$(printf '%s\n' "$out" | head -n 1 | cut -f3)
  if [ "$state" = replied ]; then
    printf 'ask %s to Sapna closed; Nova already reported envelope %s, so nothing was sent\n' "$id" "$ref"
    record_settled "$marker" "nova already reported $ref"
    return 0
  fi
  text="$(outcome_text "$id" "$title" "$how" "$pr" "$report" "$note" "$reason"). Settle $ref by its state (fleet-handoff references/status-and-gotchas.md), then report this one."
  if ! out=$(FM_HANDOFF_FM_HOME="$FM_HOME" "$HANDOFF" to-nova "Settled: $title" --kind reply --reply-to "$ref" \
      --item "$id" --domain sapna --ask "$text" 2>&1); then
    printf 'fm-asks: ask %s to Sapna closed, but the settlement to Nova failed, so Nova was not told about envelope %s: %s\n' "$id" "$ref" "$(printf '%s' "$out" | tail -n 1)" >&2
    return 1
  fi
  reply_id=$(printf '%s\n' "$out" | sed -n 's/^handed //p' | head -n 1)
  printf 'ask %s to Sapna closed; told Nova on %s (reply to envelope %s)\n' "$id" "${reply_id:-a reply envelope}" "$ref"
  record_settled "$marker" "told nova on ${reply_id:-?} (reply to $ref)"
}

record_settled() {  # <marker> <line>; the ask it settled is $asked
  mkdir -p "${1%/*}" 2>/dev/null && printf '%s %s\nasked=%s\n' "$(today)" "$2" "$asked" > "$1" \
    || printf 'fm-asks: could not record %s; a replayed close may settle it again\n' "$1" >&2
}

case "${1:-}" in
  ''|-h|--help|help) usage; exit 0 ;;
  list) shift; command_list "$@" ;;
  settle) shift; command_settle "$@" ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac

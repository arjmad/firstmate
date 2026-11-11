# shellcheck shell=bash
# fm-backlog-row-lib.sh - the shape of a backlog row: hold kinds, dates, and
# the Due: and Batch: body lines.
# Usage: . bin/fm-backlog-row-lib.sh
#
# Fork patch (docs/fork-decisions/2026-11-08-backlog-row-shape.md). A row
# answers who moves next (the `Owner:` line, bin/fm-backlog-owner-lib.sh), why
# not now (its hold kind), and when (its dates), in fixed fields; the title is
# the next action in plain words and carries no date.
#
# Hold kinds, used strictly:
#   captain   needs the captain's answer or his hands;
#   external  someone else must act, even when the captain owns the follow-up;
#   future    nothing to do until a date;
#   parked    someday.
# Every hold carries a date: future, parked and external holds their back-on
# date (tasks-axi's hold-until, which for an external wait is the recheck
# date), since that is what lifts them. A new captain call stays live with no
# back-on date, because tasks-axi lifts a hold on its date, and carries a due
# date instead (bin/fm-captain-hold.sh).
#
# Two dates stay apart. The back-on date is when the row comes back; the due
# date is the real deadline, and a snooze never moves it. tasks-axi has no due
# field and no labels, so both extra fields are body lines of their own, like
# the owner:
#
#   Due: YYYY-MM-DD
#   Batch: <tag>
#
# A Batch tag groups rows the captain works off together, and names its group
# by structured fields only (fork patch,
# docs/fork-decisions/2026-11-11-calls-grouped-by-what-it-takes.md):
#   Batch: place:<name>      an errand list for one place, such as
#                            `place:office`; <name> is a lowercase slug
#   Batch: board:<task-id>   a member of the board that task id carries
# A bare lowercase slug (`Batch: office`, written before the prefixes) still
# reads, and counts as a place list. fm_backlog_batch_class owns the group
# class a tag gives. bin/fm-captain-hold.sh `defer-batch` defers, and
# `answer-batch` answers, every captain call carrying one tag. A reader takes
# the last matching line, a writer replaces only that line, and a body that
# names none has none. Startup and board readers outside this file depend on
# this exact `Due:` format, and bin/fm-fleet-snapshot.sh reads the `Batch:`
# line with the same pattern.
#
# This file defines functions only.

# fm_backlog_hold_kind_valid <kind>: succeed for one of the four hold kinds.
fm_backlog_hold_kind_valid() {
  case "${1:-}" in
    captain|external|future|parked) return 0 ;;
  esac
  return 1
}

# fm_backlog_date_valid <value>: succeed for a real YYYY-MM-DD calendar date.
fm_backlog_date_valid() {
  local value=${1:-} year month day max
  [[ "$value" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  year=$((10#${BASH_REMATCH[1]}))
  month=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  [ "$month" -ge 1 ] && [ "$month" -le 12 ] && [ "$day" -ge 1 ] || return 1
  case "$month" in
    4|6|9|11) max=30 ;;
    2)
      if [ $((year % 4)) -eq 0 ] && { [ $((year % 100)) -ne 0 ] || [ $((year % 400)) -eq 0 ]; }; then
        max=29
      else
        max=28
      fi
      ;;
    *) max=31 ;;
  esac
  [ "$day" -le "$max" ]
}

# fm_backlog_batch_valid <tag>: succeed for `place:<slug>`, `board:<task-id>`,
# or a bare lowercase slug, each part lowercase.
fm_backlog_batch_valid() {
  [[ "${1:-}" =~ ^(place:)?[a-z0-9][a-z0-9-]{0,39}$ ]] \
    || [[ "${1:-}" =~ ^board:[a-z0-9][a-z0-9._-]{0,127}$ ]]
}

# fm_backlog_batch_class <tag>: print the group class a tag gives, `board` or
# `place` (a bare legacy slug is a place list).
fm_backlog_batch_class() {
  case "${1:-}" in
    board:*) printf 'board' ;;
    *) printf 'place' ;;
  esac
}

# shellcheck disable=SC2034  # read by the scripts that source this file
FM_BACKLOG_BATCH_RULE='a batch tag is place:<name> or board:<task-id> in lowercase letters, digits and dashes (a task id may also hold dots and underscores), or a bare legacy slug'

# fm_backlog_title_dated <title>: succeed when the title opens with a
# `[YYYY-MM-DD]` date, which belongs in the hold or the Due: line instead.
fm_backlog_title_dated() {
  [[ "${1:-}" =~ ^[[:space:]]*\[[0-9]{4}-[0-9]{2}-[0-9]{2}\] ]]
}

# The line pattern of a field. It avoids interval expressions so every awk
# reads it; fm_backlog_batch_valid bounds a tag's length where one is written.
fm_backlog_row_field_pattern() {  # <due|batch>
  case "$1" in
    due) printf '%s' '^[[:space:]]*Due:[[:space:]]*([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])[[:space:]]*$' ;;
    batch) printf '%s' '^[[:space:]]*Batch:[[:space:]]*((place:)?[a-z0-9][a-z0-9-]*|board:[a-z0-9][a-z0-9._-]*)[[:space:]]*$' ;;
    *) return 1 ;;
  esac
}

fm_backlog_row_field_label() {  # <due|batch>
  case "$1" in
    due) printf 'Due' ;;
    batch) printf 'Batch' ;;
    *) return 1 ;;
  esac
}

# fm_backlog_row_field_of_body <due|batch> <decoded-body>: print the recorded
# value, or nothing.
fm_backlog_row_field_of_body() {
  local pattern
  pattern=$(fm_backlog_row_field_pattern "$1") || return 1
  printf '%s\n' "${2:-}" | sed -En "s/$pattern/\\1/p" | tail -1
}

fm_backlog_row_trim_trailing_blank() {  # <text>
  local text=${1:-}
  while [ -n "$text" ] && [ -z "$(printf '%s\n' "$text" | tail -1 | tr -d '[:space:]')" ]; do
    text=$(printf '%s\n' "$text" | sed '$d')
  done
  printf '%s' "$text"
}

# fm_backlog_row_field_body_with <due|batch> <decoded-body> <value-or-empty>:
# print the body with its canonical (last) line of that field removed and,
# for a non-empty value, a new one at the end, above a trailing owner line so
# the owner stays last.
fm_backlog_row_field_body_with() {
  local field=$1 body=${2:-} value=${3:-} pattern label kept owner_line rest
  pattern=$(fm_backlog_row_field_pattern "$field") || return 1
  label=$(fm_backlog_row_field_label "$field") || return 1
  # A trailing owner line stays last (bin/fm-backlog-owner-lib.sh): detach it,
  # write the field on the rest, and put it back.
  rest=$(fm_backlog_row_trim_trailing_blank "$body")
  owner_line=$(printf '%s\n' "$rest" | tail -1)
  if [ -n "$value" ] && printf '%s\n' "$owner_line" | grep -Eq '^[[:space:]]*Owner:[[:space:]]*(arjun|fleet)[[:space:]]*$'; then
    rest=$(fm_backlog_row_trim_trailing_blank "$(printf '%s\n' "$rest" | sed '$d')")
    fm_backlog_row_field_body_with "$field" "$rest" "$value"
    printf '\n%s\n' "$owner_line"
    return 0
  fi
  # Removing the line also drops a blank line before it that would otherwise
  # double up with the one after it.
  kept=$(printf '%s\n' "$body" | PATTERN=$pattern awk '
    function blank(s) { return s ~ /^[[:space:]]*$/ }
    { line[NR] = $0 }
    $0 ~ ENVIRON["PATTERN"] { last = NR }
    END {
      drop = 0
      if (last > 1 && blank(line[last - 1]) && (last == NR || blank(line[last + 1]))) drop = last - 1
      for (i = 1; i <= NR; i++) if (i != last && i != drop) print line[i]
    }
  ')
  kept=$(fm_backlog_row_trim_trailing_blank "$kept")
  if [ -z "$value" ]; then
    [ -z "$kept" ] || printf '%s\n' "$kept"
  elif printf '%s\n' "$kept" | tail -1 | grep -Eq '^(Due|Batch): '; then
    # Row fields written together stay one block.
    printf '%s\n%s: %s\n' "$kept" "$label" "$value"
  elif [ -n "$kept" ]; then
    printf '%s\n\n%s: %s\n' "$kept" "$label" "$value"
  else
    printf '%s: %s\n' "$label" "$value"
  fi
}

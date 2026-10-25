# shellcheck shell=bash
# fm-backlog-prune-lib.sh - the one rule for which backlog rows the weekly
# prune card proposes to drop, and the one record a drop leaves on its row.
# Usage: . bin/fm-backlog-prune-lib.sh; splice "$FM_PRUNE_JQ_DEFS" ahead of a
# jq program over fm-fleet-snapshot.sh backlog records.
#
# A row is a prune candidate when all of these hold, read from structured
# fields only:
#   - it is a structured Queued row (never In flight, never Done);
#   - its recorded owner is `fleet` (bin/fm-backlog-owner-lib.sh), so a row
#     the captain owns, or one that records no owner, is never proposed;
#   - it carries no hold of any kind (no hold reason, kind, or until date),
#     because a held row - for the captain, parked, waiting outside, or
#     scheduled for a date - is waiting on purpose;
#   - no unfinished work blocks it, and no open row waits on it, because a
#     drop closes the row and a closed row clears the blockers that name it;
#   - no live task record (state/<id>.meta) carries its id;
#   - it is not a public-followup obligation tasks-axi files itself;
#   - it was last touched at least FM_BACKLOG_PRUNE_AGE_DAYS (default 14) days
#     ago.
# "Last touched" is the newest calendar date written on the row that is not
# after today: its filed (since) date, its hold-set stamp, and any YYYY-MM-DD
# date on its line, in its decoded hold reason, or on a body line, which is
# where every dated note, re-hold, reclassification, and earlier drop lands.
# Reading every date only ever makes a row look fresher, so the rule errs
# toward keeping a row; a row with no readable date is never proposed.
#
# Dates compare as UTC calendar dates throughout, the same today the
# bearings snapshot uses.
#
# A drop is a tasks-axi close whose note is one body line of its own:
#
#   dropped by <captain>'s prune, <YYYY-MM-DD>
#
# written by bin/fm-backlog-prune.sh and nowhere else, dated in UTC.
# prune_dropped is the one reader of that line: bin/fm-landed-lib.sh keeps a
# dropped row with no delivery artifact out of Recently Landed, because a drop
# is not a delivery, while a row reopened and later delivered (a merged PR, a
# report, a local landing) still lands. Nothing is deleted, so
# `fm-tasks-axi.sh reopen <id>` brings a dropped row back, and the line then
# counts as a touch on that date.
#
# fm_backlog_prune_age_days is the one parser of FM_BACKLOG_PRUNE_AGE_DAYS.
#
# This file defines variables and one function.

# fm_backlog_prune_age_days: print the age threshold in days, a positive
# decimal integer (default 14), or fail when FM_BACKLOG_PRUNE_AGE_DAYS is set
# to anything else.
fm_backlog_prune_age_days() {
  local v=${FM_BACKLOG_PRUNE_AGE_DAYS:-14}
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#v}" -le 5 ] || return 1
  v=$((10#$v))
  [ "$v" -gt 0 ] || return 1
  printf '%s\n' "$v"
}

# shellcheck disable=SC2016,SC2034 # jq, not the shell, expands $; read by the caller.
FM_PRUNE_JQ_DEFS='
  def prune_date_epoch:
    if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
    then (try ((. + "T00:00:00Z") | fromdateiso8601) catch null)
    else null end;
  def prune_touched($today):
    ([ (.since // empty), ((.hold_set // "") | .[0:10]),
       ([(.raw // ""), (.hold_reason // "")] + (.body_lines // []))[]
         | strings
         | scan("(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])") ]
     | map(select(type == "string" and . <= $today and (prune_date_epoch != null)))
     | max);
  def prune_age_days($touched; $today):
    (($today | prune_date_epoch) - ($touched | prune_date_epoch)) / 86400 | floor;
  def prune_dropped:
    any((.body_lines // [])[]; strings | test("^dropped by .+'"'"'s prune, [0-9]{4}-[0-9]{2}-[0-9]{2}\\.?$"; "i"));
  # Every id an open row still waits on.
  def prune_depended_ids($records):
    [ $records[] | select(.structured == true and .state != "done")
      | (.unresolved_blocker_ids // [])[] ] | unique;
  # Why a row is not a candidate, or null when it is one.
  def prune_refusal($today; $min_age; $live_ids; $depended_ids):
    . as $row
    | prune_touched($today) as $touched
    | if .structured != true then "not a structured backlog row"
      elif .state != "queued" then "no longer queued"
      elif .hold_kind == "captain" then "held for the captain"
      elif .hold_kind != null or .hold_reason != null or .hold_until != null then "held"
      elif .owned_by != "fleet" then "not owned by the fleet"
      elif ((.unresolved_blocker_ids // []) | length) > 0 then "blocked by other work"
      elif ($depended_ids | index($row.id)) != null then "open work waits on it"
      elif ($live_ids | index($row.id)) != null then "has a live task record"
      elif (.kind // "") == "public-followup" then "a public follow-up obligation"
      elif $touched == null then "no readable date"
      elif prune_age_days($touched; $today) < $min_age then "touched \($touched)"
      else null end;
  def prune_candidate($today; $min_age; $live_ids; $depended_ids):
    prune_refusal($today; $min_age; $live_ids; $depended_ids) == null;
  def prune_row($today):
    prune_touched($today) as $touched
    | {id, title:(.title // .id), repo:(.repo // null), kind:(.kind // null),
       filed:(.since // null), touched:$touched, age_days:prune_age_days($touched; $today)};
  # Every candidate, oldest touch first, then by id.
  def prune_candidates($records; $today; $min_age; $live_ids):
    prune_depended_ids($records) as $depended
    | [ $records[] | select(prune_candidate($today; $min_age; $live_ids; $depended)) | prune_row($today) ]
    | sort_by([.touched, .id]);
'

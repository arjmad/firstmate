#!/usr/bin/env bash
# Land a green skill-capture note automatically, so only failures reach
# firstmate (fork patch, docs/fork-decisions/2026-11-06-capture-autoland.md).
#
# A capture job (Nova's cron/skill-capture.sh) reports a green run as one
# captain inbox note through bin/fm-inbox.sh note:
#   <tag> skill capture green: <n> path(s) in <pr-url> at <sha>
#   Land it: <path>/fm-capture-land.sh <pr-url> --head <sha>
# Firstmate used to spend a main-session turn running that line by hand.
# When this home opts the note's subject tag in, bin/fm-inbox.sh hands such a
# note to `take` before it appends any wake, and `take` starts a detached
# `run` that executes this repository's own bin/fm-capture-land.sh with the
# note's two arguments. Every guard of that command and of bin/fm-pr-merge.sh
# still decides. A landed note is acknowledged with no wake at all. Any other
# outcome - a refusal, a merge queue, an unsettled checkout, a crash - announces
# the note to firstmate exactly as before, with the exit code, the last output
# line, and the log path in the wake reason.
#
# Usage:
#   fm-capture-autoland.sh match <note-file>
#   fm-capture-autoland.sh take <note-id>
#   fm-capture-autoland.sh run <note-id>
#
# match  Print "<pr-url> <sha>" and exit 0 when <note-file> is an opted-in
#        green capture note; exit 1 otherwise. A match needs all of:
#          - config/capture-autoland lists the body's leading subject tag (one
#            tag per line, such as `[nova-skills]`; blank and # lines ignored);
#            an absent file turns the whole feature off;
#          - the body is exactly the two lines above, nothing more;
#          - the green line and the Land it line name the same GitHub pull
#            request URL and the same full 40-character lowercase sha;
#          - the Land it command is this repository's own
#            bin/fm-capture-land.sh (the same file, by -ef). The note's path is
#            never executed: `run` executes this repository's copy.
# take   Called by bin/fm-inbox.sh for a pending note before it announces it.
#        Exit 0 means the note now belongs to the lander and must not be
#        announced: it matched, and either this call started its detached
#        `run` or an earlier call already had (state/inbox/autoland/<id>.taken,
#        created exclusively). Exit 1 means announce it as usual: no match, or
#        the lander could not be started.
# run    The detached lander; never run it in a conversational turn. Re-checks
#        the note is still pending and still matches, runs
#        `fm-capture-land.sh <pr-url> --head <sha>` with output to
#        state/inbox/autoland/<id>.log, then acknowledges the note with
#        `fm-inbox.sh drain --ack <id>` on exit 0, or wakes firstmate with
#        `fm-inbox.sh announce --why <reason> <id>` on any other exit.
#
# Recovery: a lander that dies before either step leaves the note pending and
# unannounced; bin/fm-inbox.sh rewake-due re-wakes it within a day and
# `fm-inbox.sh unread` lists it at session start, so it is never lost.
set -u

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

case "${1:-}" in -h|--help) usage 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
INBOX="$STATE/inbox"
DIR="$INBOX/autoland"
LAND="$SCRIPT_DIR/fm-capture-land.sh"

note_id_valid() {
  case "${1-}" in ''|*/*|*..*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# The note's leading subject tag is one config/capture-autoland line.
tag_opted_in() {  # <tag>
  [ -f "$CONFIG/capture-autoland" ] || return 1
  awk -v tag="$1" '
    { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    $0 == "" || /^#/ { next }
    $0 == tag { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$CONFIG/capture-autoland"
}

cmd_match() {
  local file=${1-} body line1 line2 tag rest url sha cmd land_url flag land_sha extra
  [ -f "$file" ] || return 1
  body=$(awk 'found { print; next } /^--$/ { found = 1 }' "$file")
  [ "$(printf '%s\n' "$body" | awk 'END { print NR }')" = 2 ] || return 1
  line1=$(printf '%s\n' "$body" | sed -n 1p)
  line2=$(printf '%s\n' "$body" | sed -n 2p)

  tag=${line1%% *}
  case "$tag" in '['*']') ;; *) return 1 ;; esac
  tag_opted_in "$tag" || return 1
  rest=${line1#"$tag skill capture green: "}
  [ "$rest" != "$line1" ] || return 1
  [[ "$rest" =~ ^[0-9]+\ path\(s\)\ in\ (https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+)\ at\ ([0-9a-f]{40})$ ]] || return 1
  url=${BASH_REMATCH[1]}
  sha=${BASH_REMATCH[2]}

  case "$line2" in 'Land it: '*) ;; *) return 1 ;; esac
  read -r cmd land_url flag land_sha extra <<< "${line2#Land it: }"
  [ -z "${extra-}" ] && [ "$land_url" = "$url" ] && [ "$flag" = --head ] && [ "$land_sha" = "$sha" ] || return 1
  [ "${cmd##*/}" = fm-capture-land.sh ] && [ "$cmd" -ef "$LAND" ] || return 1
  printf '%s %s\n' "$url" "$sha"
}

cmd_take() {
  local id=${1-} marker
  note_id_valid "$id" || return 1
  cmd_match "$INBOX/$id.note" >/dev/null || return 1
  mkdir -p "$DIR" || return 1
  marker="$DIR/$id.taken"
  ( set -C; date -u +%Y-%m-%dT%H:%M:%SZ > "$marker" ) 2>/dev/null || {
    [ -f "$marker" ] && return 0
    return 1
  }
  if [ ! -x "$SCRIPT_DIR/fm-capture-autoland.sh" ] || [ ! -x "$LAND" ]; then
    rm -f -- "$marker"
    return 1
  fi
  # Detached with every descriptor redirected, so a caller that waits on its
  # child's output (bin/fm-inbox.sh run by a job's notifier) returns at once,
  # and in its own process group (set -m, as bin/fm-fleet-sync.sh starts a
  # capture), so a job runner that reaps its group cannot kill the land.
  ( set -m; nohup "$SCRIPT_DIR/fm-capture-autoland.sh" run "$id" </dev/null >>"$DIR/$id.log" 2>&1 & )
  return 0
}

cmd_run() {
  local id=${1-} found url sha rc=0 log last
  note_id_valid "$id" || { echo "invalid note id: $id" >&2; return 2; }
  log="$DIR/$id.log"
  if [ ! -f "$INBOX/$id.note" ]; then
    echo "note $id is no longer pending; nothing to land"
    return 0
  fi
  if ! found=$(cmd_match "$INBOX/$id.note"); then
    "$SCRIPT_DIR/fm-inbox.sh" announce --why "capture autoland: note no longer matches config/capture-autoland" "$id"
    return 1
  fi
  read -r url sha <<< "$found"
  echo "autoland: $LAND $url --head $sha"
  "$LAND" "$url" --head "$sha" </dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    "$SCRIPT_DIR/fm-inbox.sh" drain --ack "$id"
    return 0
  fi
  last=$(grep -v '^autoland: ' "$log" 2>/dev/null | tail -n 1 | tr '\t' ' ' | cut -c1-160)
  "$SCRIPT_DIR/fm-inbox.sh" announce --why "capture autoland failed (exit $rc): ${last:-no output}; log $log" "$id"
  return 1
}

case "${1:-}" in
  match) shift; cmd_match "$@" ;;
  take)  shift; cmd_take "$@" ;;
  run)   shift; cmd_run "$@" ;;
  *) usage ;;
esac

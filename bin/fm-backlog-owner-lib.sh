# shellcheck shell=bash
# fm-backlog-owner-lib.sh - the one record of who owns a backlog row's next move.
# Usage: . bin/fm-backlog-owner-lib.sh
#
# Every open backlog row names an owner: `arjun` when only the captain can move
# it (his own to-do, a decision, a sign-in), `fleet` when firstmate or a
# crewmate moves it, including a dated check the fleet makes and reports back
# on. tasks-axi has no free-form field and refuses an unknown trailing tag, so
# the owner lives in the row body as one line of its own:
#
#   Owner: arjun
#   Owner: fleet
#
# Writers keep exactly one such line, at the end of the body, so the blocks
# bin/fm-captain-hold.sh prepends (hold-set stamp, resolution records,
# deferrals) never displace it. A reader takes the last matching line, which
# is the canonical one even when quoted captain words above it happen to
# contain the same text. bin/fm-fleet-snapshot.sh reads the same line from the
# markdown backlog and is pinned to this format by its tests.
#
# Who sets it: bin/fm-tasks-axi.sh at `add` (default by kind, required for
# kind=captain) and through its `owner` subcommand; bin/fm-captain-hold.sh at
# `hold` (arjun) and when a released hold hands the row back (fleet).
#
# This file defines functions only.

FM_BACKLOG_OWNER_PREFIX='Owner: '

# fm_backlog_owner_valid <value>: succeed for a recognized owner.
fm_backlog_owner_valid() {
  case "${1:-}" in
    arjun|fleet) return 0 ;;
  esac
  return 1
}

# fm_backlog_owner_default <kind>: print the owner a new row of <kind> gets
# when its filer names none; fail for kind=captain, which must name one because
# a captain row may be the captain's own to-do or the fleet's errand for him.
fm_backlog_owner_default() {
  [ "${1:-}" != captain ] || return 1
  printf 'fleet\n'
}

# fm_backlog_owner_of_body <decoded-body>: print the recorded owner, or nothing.
fm_backlog_owner_of_body() {
  printf '%s\n' "${1:-}" | sed -En 's/^[[:space:]]*Owner:[[:space:]]*(arjun|fleet)[[:space:]]*$/\1/p' | tail -1
}

# fm_backlog_owner_body_with <decoded-body> <owner>: print the body carrying
# exactly one owner line, <owner>, at its end; every earlier owner line goes.
fm_backlog_owner_body_with() {
  local body=${1:-} owner=$2 kept
  kept=$(printf '%s\n' "$body" | sed -E '/^[[:space:]]*Owner:[[:space:]]*(arjun|fleet)[[:space:]]*$/d')
  # Command substitution already dropped trailing newlines; drop trailing
  # blank lines too so the owner line is separated by exactly one blank line.
  while [ -n "$kept" ] && [ -z "$(printf '%s\n' "$kept" | tail -1 | tr -d '[:space:]')" ]; do
    kept=$(printf '%s\n' "$kept" | sed '$d')
  done
  if [ -n "$kept" ]; then
    printf '%s\n\n%s%s\n' "$kept" "$FM_BACKLOG_OWNER_PREFIX" "$owner"
  else
    printf '%s%s\n' "$FM_BACKLOG_OWNER_PREFIX" "$owner"
  fi
}

# fm_backlog_owner_shown_body <tasks-axi-show-output>: print the decoded body
# of a `tasks-axi show --full` read, empty for tasks-axi's `-` marker. A body
# with line breaks arrives as one JSON-quoted string.
fm_backlog_owner_shown_body() {
  local value
  value=$(printf '%s\n' "${1:-}" | sed -n 's/^  body: //p' | head -1)
  case "$value" in
    \"*\")
      value=$(printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      ') || return 1
      ;;
  esac
  [ "$value" = - ] || printf '%s' "$value"
}

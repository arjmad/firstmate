#!/usr/bin/env bash
# fm-state-residue-sweep.sh - retire the watcher's per-endpoint bookkeeping
# under state/ once the endpoint it describes is provably gone, and rotate the
# scratch files two supervision scripts can leave behind.
#
# Usage: fm-state-residue-sweep.sh [--dry-run]
#          Prints one "BOOTSTRAP_INFO: state residue sweep: ..." line when
#          something was removed (or, under --dry-run, would have been) and
#          nothing otherwise. Every problem is a "warning:" on stderr and the
#          exit status stays 0, so a session start continues conservatively.
#        --dry-run
#          Classify and report exactly as a real run would, remove nothing, and
#          list each endpoint and scratch file that would be retired.
#
# The caller must already hold this Firstmate home's session lock:
# bin/fm-bootstrap.sh runs this as one of its locked MUTATING sweeps and skips
# it under FM_BOOTSTRAP_DETECT_ONLY=1 exactly like the others. Running it by
# hand while a live session holds the lock is safe only for --dry-run.
#
# What it sweeps. bin/fm-watch.sh keeps one family of marker files per
# supervised endpoint, each named by fm_backend_window_key (bin/fm-backend.sh)
# of that endpoint's target:
#   .hash-<key> .count-<key> .stale-<key> .stale-since-<key>
#   .wedge-escalations-<key> .churn-since-<key> .paused-<key>
#   .paused-rechecked-<key> .paused-resurfaced-<key> .writing-since-<key>
#   .writing-resurfaced-<key> .waiting-resurfaced-<key>
# The watcher only ever polls endpoints named by a current state/<id>.meta, so
# once a task's record is removed its markers are never read again, and the
# markers of every pane that died without a teardown accumulate forever.
#
# How an endpoint is proven gone. A key is only a lossy filename form of the
# target, and it records no backend, so the sweep never trusts a reconstructed
# target alone. It builds the set of candidate (backend, session) pairs this
# home actually uses - every current meta's backend and session, plus the
# home's resolved backend with its ambient session - and asks each candidate
# for one live inventory (tmux: the session's window names; herdr: the pane
# ids in the session's `api snapshot`). A key that equals the key of any live endpoint is live
# and kept, whatever its reconstructed target would have said. A key that
# matches a candidate's endpoint shape (tmux `<session>_fm-<task>`, herdr
# `<session>_w<id>_p<n>`) and no live endpoint is then asked about ONCE through
# fm_backend_agent_state, the recovery-grade classifier bin/fm-backend.sh owns,
# and its records are removed only on `missing` or `dead`. `alive` keeps the
# records as live; `ambiguous`, `unreadable`, and `unverified` keep them as
# unresolved; a key matching no candidate at all (a backend this home no
# longer runs, zellij/orca/cmux, a remote secondmate route, or a shape this
# sweep does not know) is kept as unmatched. Records keyed by a target named in
# any current state/<id>.meta are never queried at all. Backend answers are
# never cached across runs: a kept key is simply asked again next time.
#
# Records keyed by task id (.seen-<task>_status, .hb-surfaced-<task>, the
# daemon's .subsuper-*) are the per-task cleanup's concern and are not touched
# here.
#
# Scratch rotation. bin/fm-claude-stop-autoarm.sh captures each arm attempt in
# state/.claude-autoarm-output.<random> and bin/fm-wake-drain.sh stages a row
# rewrite in state/.wake-rows.consume.<random>; both remove their file on every
# ordinary path, so one older than FM_STATE_RESIDUE_SCRATCH_MAX_AGE_DAYS was
# orphaned by a killed process and is removed. The threshold is a constant,
# not a config file: no live scratch file is ever that old (an arm attempt
# lasts seconds; a row rewrite holds the queue lock), so there is nothing to
# tune.
#
# Cost bound. Every backend question is one CLI call, and a home that has
# accumulated hundreds of dead keys asks them all on its first run, so the
# sweep asks at most FM_STATE_RESIDUE_QUERY_BUDGET endpoints per run and
# leaves the rest for the next session start; the summary line reports the
# deferred count. The inventories are one call per candidate regardless.
#
# Dry run and the summary line are the only stdout. The kept counts are
# reported so an operator can see that a live or unreadable endpoint held its
# records back rather than the sweep silently doing nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Scratch files older than this many days are orphans; see the header.
FM_STATE_RESIDUE_SCRATCH_MAX_AGE_DAYS=7
# Endpoint questions per run; see "Cost bound" in the header.
FM_STATE_RESIDUE_QUERY_BUDGET=400

# Longest prefixes first, so `.stale-since-K` is read as key K under
# `.stale-since-` and never as key `since-K` under `.stale-`.
FM_STATE_RESIDUE_PREFIXES='.stale-since- .paused-rechecked- .paused-resurfaced- .writing-since- .writing-resurfaced- .waiting-resurfaced- .wedge-escalations- .churn-since- .hash- .count- .stale- .paused-'
FM_STATE_RESIDUE_SCRATCH_PREFIXES='.claude-autoarm-output. .wake-rows.consume.'

DRY_RUN=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1; [ "$#" -eq 1 ] || { echo "usage: fm-state-residue-sweep.sh [--dry-run]" >&2; exit 2; } ;;
  *) echo "usage: fm-state-residue-sweep.sh [--dry-run]" >&2; exit 2 ;;
esac

warn() { printf 'warning: state residue sweep: %s\n' "$*" >&2; }

# --- candidate (backend, session) pairs --------------------------------------

CANDIDATES=
add_candidate() {  # <backend> <session>
  local backend=$1 session=$2
  [ -n "$backend" ] && [ -n "$session" ] || return 0
  case "$backend" in tmux|herdr) ;; *) return 0 ;; esac
  case "$session" in *' '*|*'|'*) return 0 ;; esac
  case "$CANDIDATES" in *"|$backend $session|"*) return 0 ;; esac
  CANDIDATES="$CANDIDATES|$backend $session|"
}

# The home's own resolved backend and its ambient session, read the way the
# adapters read them but without creating anything: fm_backend_tmux_container_ensure
# would create the detached "firstmate" session, so its choice is mirrored here.
ambient_candidate() {
  local backend session
  backend=$(fm_backend_name 2>/dev/null) || return 0
  case "$backend" in
    tmux)
      if [ -n "${TMUX:-}" ]; then
        session=$(tmux display-message -p '#S' 2>/dev/null) || return 0
      else
        session=firstmate
      fi
      ;;
    herdr)
      fm_backend_source herdr 2>/dev/null || return 0
      session=$(fm_backend_herdr_session)
      ;;
    *) return 0 ;;
  esac
  add_candidate "$backend" "$session"
}

# --- protected keys: every target a current meta names -----------------------

PROTECTED=
collect_protected() {
  local meta backend target session
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    PROTECTED="$PROTECTED|$(fm_backend_window_key "$target")|"
    backend=$(fm_backend_of_meta "$meta")
    case "$target" in
      *:*) session=${target%%:*} ;;
      *) continue ;;
    esac
    [ "$backend" = herdr ] && [ -n "$(fm_meta_get "$meta" herdr_session)" ] \
      && session=$(fm_meta_get "$meta" herdr_session)
    add_candidate "$backend" "$session"
  done
}

# --- live inventories, one per candidate ---------------------------------------

# LIVE_KEYS collects the key of every live endpoint across every candidate whose
# inventory could be read. INVENTORY_OK lists the candidates that answered, so a
# candidate whose inventory failed never contributes a "gone" verdict below.
LIVE_KEYS=
INVENTORY_OK=
read_inventories() {
  local pair backend session names name status
  for pair in $(printf '%s' "$CANDIDATES" | tr '|' '\n' | tr ' ' ','); do
    backend=${pair%%,*}
    session=${pair#*,}
    case "$backend" in
      tmux)
        fm_backend_source tmux 2>/dev/null || continue
        status=0
        names=$(fm_backend_tmux_window_inventory "$session") || status=$?
        # A session or server that is positively absent has no live windows,
        # the same authoritative absence the recovery classifier maps to
        # `missing`; any other failure leaves this candidate unable to certify
        # absence.
        case "$status" in
          0) ;;
          2) names= ;;
          *) continue ;;
        esac
        ;;
      herdr)
        fm_backend_source herdr 2>/dev/null || continue
        command -v jq >/dev/null 2>&1 || continue
        # One session-wide snapshot rather than a per-workspace pane list. The
        # leading "ok" line proves the body parsed as a pane array, so an empty
        # session is told apart from a stopped server or a protocol refusal,
        # both of which print nothing and leave the candidate unreadable.
        names=$(fm_backend_herdr_cli "$session" api snapshot 2>/dev/null \
          | jq -r 'if (.result.snapshot.panes | type) == "array"
                   then "ok", (.result.snapshot.panes[] | .pane_id // empty)
                   else empty end' 2>/dev/null) || names=
        case "$names" in
          ok|ok$'\n'*) names=${names#ok} ;;
          *)
            # No snapshot. A positively stopped session server has no live
            # panes, the same authoritative absence the recovery classifier
            # maps to `missing`; anything less leaves this candidate unable to
            # certify absence.
            [ "$(fm_backend_herdr_server_running_state "$session")" = stopped ] || continue
            names=
            ;;
        esac
        ;;
      *) continue ;;
    esac
    INVENTORY_OK="$INVENTORY_OK|$backend $session|"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      LIVE_KEYS="$LIVE_KEYS|$(fm_backend_window_key "$session:$name")|"
    done <<EOF
$names
EOF
  done
}

# --- keys on disk --------------------------------------------------------------

# key_of <basename>: the key a marker file is named by, or nothing when the name
# carries none of the watcher's prefixes.
key_of() {
  local name=$1 prefix
  for prefix in $FM_STATE_RESIDUE_PREFIXES; do
    case "$name" in
      "$prefix"*) printf '%s' "${name#"$prefix"}"; return 0 ;;
    esac
  done
  return 1
}

# match_candidate <key>: print "<backend> <target>" for the one candidate whose
# session prefix and endpoint shape the key fits, print nothing when none fits,
# and fail when more than one fits (an ambiguous key is left alone).
match_candidate() {
  local key=$1 pair backend session skey rest found='' n=0
  for pair in $(printf '%s' "$CANDIDATES" | tr '|' '\n' | tr ' ' ','); do
    backend=${pair%%,*}
    session=${pair#*,}
    skey=$(fm_backend_window_key "$session")
    case "$key" in "${skey}_"*) ;; *) continue ;; esac
    rest=${key#"${skey}_"}
    case "$backend" in
      tmux)
        case "$rest" in fm-*) ;; *) continue ;; esac
        case "$rest" in *[!A-Za-z0-9_-]*|'') continue ;; esac
        found="$backend $session:$rest"
        ;;
      herdr)
        case "$rest" in w*_p*) ;; *) continue ;; esac
        case "${rest%%_*}" in w) continue ;; w*[!A-Za-z0-9]*) continue ;; esac
        case "${rest#*_}" in p) continue ;; p*[!0-9]*) continue ;; *_*) continue ;; esac
        found="$backend $session:${rest%%_*}:${rest#*_}"
        ;;
    esac
    n=$((n + 1))
  done
  [ "$n" -le 1 ] || return 1
  [ -z "$found" ] || printf '%s' "$found"
}

remove_key_records() {  # <key>
  local key=$1 prefix path n=0
  for prefix in $FM_STATE_RESIDUE_PREFIXES; do
    path="$STATE/$prefix$key"
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      n=$((n + 1))
    elif rm -f -- "$path"; then
      n=$((n + 1))
    else
      warn "could not remove $path"
    fi
  done
  printf '%s' "$n"
}

sweep_endpoint_records() {
  local name key keys='' pair target backend verdict removed
  for name in "$STATE"/.*; do
    [ -f "$name" ] && [ ! -L "$name" ] || continue
    key=$(key_of "$(basename "$name")") || continue
    [ -n "$key" ] || continue
    case "$keys" in *"|$key|"*) continue ;; esac
    keys="$keys|$key|"
  done
  [ -n "$keys" ] || return 0
  for key in $(printf '%s' "$keys" | tr '|' '\n'); do
    [ -n "$key" ] || continue
    case "$PROTECTED" in *"|$key|"*) KEPT_META=$((KEPT_META + 1)); continue ;; esac
    case "$LIVE_KEYS" in *"|$key|"*) KEPT_LIVE=$((KEPT_LIVE + 1)); continue ;; esac
    if ! pair=$(match_candidate "$key"); then
      KEPT_UNRESOLVED=$((KEPT_UNRESOLVED + 1))
      continue
    fi
    if [ -z "$pair" ]; then
      KEPT_UNMATCHED=$((KEPT_UNMATCHED + 1))
      continue
    fi
    backend=${pair%% *}
    target=${pair#* }
    # Only a candidate whose inventory was read may certify absence: the
    # classifier's own inventory read is authoritative for tmux, but the
    # herdr per-pane read runs against a session whose pane list was not
    # readable a moment ago, and a positive "gone" from a server that cannot
    # list its panes is not the proof this sweep requires.
    case "$INVENTORY_OK" in
      *"|$backend ${target%%:*}|"*) ;;
      *) KEPT_UNRESOLVED=$((KEPT_UNRESOLVED + 1)); continue ;;
    esac
    if [ "$QUERIES" -ge "$FM_STATE_RESIDUE_QUERY_BUDGET" ]; then
      DEFERRED=$((DEFERRED + 1))
      continue
    fi
    QUERIES=$((QUERIES + 1))
    verdict=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || verdict=unreadable
    case "$verdict" in
      missing|dead)
        removed=$(remove_key_records "$key")
        [ "$DRY_RUN" -eq 0 ] || printf 'would retire %s record(s) for %s endpoint %s (%s)\n' "$removed" "$backend" "$target" "$verdict"
        REMOVED_RECORDS=$((REMOVED_RECORDS + removed))
        REMOVED_ENDPOINTS=$((REMOVED_ENDPOINTS + 1))
        ;;
      alive) KEPT_LIVE=$((KEPT_LIVE + 1)) ;;
      *) KEPT_UNRESOLVED=$((KEPT_UNRESOLVED + 1)) ;;
    esac
  done
}

# --- scratch rotation ----------------------------------------------------------

rotate_scratch() {
  local prefix path max_age
  max_age=$((FM_STATE_RESIDUE_SCRATCH_MAX_AGE_DAYS * 86400))
  for prefix in $FM_STATE_RESIDUE_SCRATCH_PREFIXES; do
    for path in "$STATE/$prefix"*; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      [ "$(fm_path_age "$path")" -gt "$max_age" ] || continue
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would rotate %s\n' "$(basename "$path")"
        ROTATED=$((ROTATED + 1))
      elif rm -f -- "$path"; then
        ROTATED=$((ROTATED + 1))
      else
        warn "could not remove $path"
      fi
    done
  done
}

# --- main ----------------------------------------------------------------------

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  exit 0
fi

REMOVED_RECORDS=0 REMOVED_ENDPOINTS=0 ROTATED=0 QUERIES=0 DEFERRED=0
KEPT_META=0 KEPT_LIVE=0 KEPT_UNRESOLVED=0 KEPT_UNMATCHED=0

collect_protected
ambient_candidate
read_inventories
sweep_endpoint_records
rotate_scratch

if [ "$REMOVED_ENDPOINTS" -gt 0 ] || [ "$ROTATED" -gt 0 ]; then
  verb=removed
  [ "$DRY_RUN" -eq 0 ] || verb='would remove'
  printf 'BOOTSTRAP_INFO: state residue sweep: %s %s watcher record(s) for %s gone endpoint(s) and %s stale scratch file(s); kept %s endpoint(s) still in a task record, %s live, %s unresolved, %s unmatched' \
    "$verb" "$REMOVED_RECORDS" "$REMOVED_ENDPOINTS" "$ROTATED" \
    "$KEPT_META" "$KEPT_LIVE" "$KEPT_UNRESOLVED" "$KEPT_UNMATCHED"
  [ "$DEFERRED" -eq 0 ] || printf ', %s deferred to the next session start' "$DEFERRED"
  printf '\n'
fi
exit 0

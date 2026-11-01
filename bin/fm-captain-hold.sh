#!/usr/bin/env bash
# fm-captain-hold.sh - deterministic mechanics for tasks held for the captain.
#
# The semantic policy is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
# report, visual-review, chat, or terminal prose to guess whether the captain
# owes an answer. The invoking agent decides what is genuinely waiting on the
# captain; this script supplies guarded creation, a durable record of what the
# captain actually said, the investigation completion gate, and the one
# keyed-answer intake every channel feeds.
#
# There is no separate decision type. A captain call is an ordinary backlog
# task held for the captain through this script's mandatory `hold` subcommand,
# and its identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/fm-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog reads and mutations address the active home's configured data
# directory the way bin/fm-backlog-transition-lib.sh does, which keeps main-home
# and secondmate-home ownership aligned with the work that discovered the call.
#
# Usage:
#   fm-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--origin <origin-id>] [--until YYYY-MM-DD] \
#     [--kind reversible|arjun-only] [--default <option> | --no-default] \
#     [--options '<A>|<B>[|<C>]' [--recommend <option>]] [--ask <question>]
#   fm-captain-hold.sh choices <task-id> --options '<A>|<B>[|<C>]' [--recommend <option>] [--ask <question>]
#   fm-captain-hold.sh release-due
#   fm-captain-hold.sh answer <task-id> --decision-file <path> [--release]
#   fm-captain-hold.sh defer <task-id> --until YYYY-MM-DD --decision-file <path>
#   fm-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance>   (keyed answers on stdin)
#   fm-captain-hold.sh reconcile-requests --source-id <source-id> --source <provenance>   (task ids on stdin)
#   fm-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   fm-captain-hold.sh unbind <source-id>
#   fm-captain-hold.sh binding <source-id>
#   fm-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   fm-captain-hold.sh board-link <origin-id> <url>
#   fm-captain-hold.sh verify <origin-id>
#   fm-captain-hold.sh open <task-id> [--identity] [--distinguish-absent]
#   fm-captain-hold.sh diverged
#   fm-captain-hold.sh reconcile list
#   fm-captain-hold.sh reconcile close <task-id> --evidence-file <path>
#   fm-captain-hold.sh reconcile note <task-id> --note-file <path>
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. Creating a missing row uses
# `tasks-axi add --kind captain`: that kind is backlog metadata, and the Beads
# adapter maps it to native issue type `task`. Captain holds have no due
# semantics (`--until` is the optional hold deferral), so the create waives
# Beads `due.required` through `BD_DUE_REQUIRED` rather than inventing a due
# date or registering a `types.custom` captain issue type. The command records
# a UTC `Captain hold set:` timestamp in the task body: repeating an active
# hold preserves the existing timestamp, while re-holding released work starts
# a new lifecycle. A task already closed is refused rather than reopened.
# `--origin` also records the origin on a `Captain hold origin:` body line, which
# `complete` and `verify` check. The reason may hold parentheses and line breaks:
# tasks-axi refuses them, so `hold` escapes them where it writes the reason and
# readers decode them (bin/fm-hold-reason-lib.sh owns the encoding).
# `hold` also records the captain as the row's owner (`Owner: arjun`, the
# record bin/fm-backlog-owner-lib.sh owns): a call held for him is his next
# move. A created row carries the line from its first write. Releasing a hold
# (`answer --release`, or a default release that lifts a work row's hold)
# hands the row back with `Owner: fleet`, because the captain has answered and
# the work resumes; record arjun again through `fm-tasks-axi.sh owner` when
# steps of his own remain.
# `--until` records the captain's own deferral date through `tasks-axi hold
# --until`, so a "revisit later" answer is stored as a date instead of a live
# card.
#
# HOLD KINDS AND DEFAULT RELEASE (fork patches, docs/fork-decisions.md
# 2026-10-14 and 2026-10-31).
# `--kind` classifies the call. `arjun-only` covers money, credentials,
# deletions, customer-facing changes, external commitments and Sapna's domain;
# it never releases itself and refuses `--default`. `reversible` is every other
# call. A reversible hold given `--default <option>` (one line, at most 200
# bytes) releases itself 72 hours after that default was first recorded, which
# enforces the captain's 2026-09-24 rule that a reversible call with a
# recommendation does not wait on him forever. A reversible hold must say what
# happens if he never answers (captain's 2026-10-30 asks-cut pick): it takes
# `--default <option>`, or `--until` when he deferred it himself, or
# `--no-default` when no option is safe to apply unasked (an idea, an open
# question); a reversible hold with none of the three is refused before any
# write, so a missing default is a recorded choice rather than an omission.
# `--no-default` stores the same `[reversible]` prefix as before and is
# refused beside `--default` or with any other kind; `--default` is refused
# beside `--until`. The kind is stored as a prefix on the stored reason, so
# every surface that shows a hold reason shows it:
#   [arjun-only] <reason>
#   [reversible] <reason>
#   [reversible; default: <option>; releases <YYYY-MM-DDTHH:MM:SSZ>] <reason>
# The prefix is the only record of the kind: a hold written without `--kind`
# (including any later re-hold, or a bare tasks-axi hold) carries no prefix and
# never releases itself, so a kind cannot outlive the reason it was given with.
# Re-holding an active hold with the same kind and default keeps its release
# time; a new default restarts the 72 hours. A caller's own reason may not
# begin with a kind prefix.
#
# CHOICES (fork patch, docs/fork-decisions.md 2026-10-31).
# A call held for the captain may carry its own choices, so every surface can
# offer them as buttons instead of a generic Done. `--options` takes two or
# three labels split on `|`; each is one line of at most 60 bytes, holds no
# `]` or `;`, is not the reserved answer `later` or `reconcile` in any case,
# and differs from the others ignoring case. `--recommend` names the
# recommended one and must equal one of them. On a reversible hold with
# `--default` the default IS the recommendation: it must be one of the
# options, and `--recommend`, when given, must equal it. Any other hold with
# `--options` must pass `--recommend`. `--ask` is the call's question as the
# captain should read it: one line of at most 200 bytes with no `]` or `;`, usable
# with or without options. Choices need `--kind`, because they ride on the
# same reason prefix, after the kind and any default, in this fixed order:
#   [arjun-only; options: A|B; recommended: A; ask: Q] <reason>
#   [reversible; options: A|B; recommended: A] <reason>
#   [reversible; default: A; releases <T>; options: A|B; recommended: A; ask: Q] <reason>
# That prefix is the one machine-readable record: tasks-axi `list` and `show`
# expose it in hold_reason, and bin/fm-bearings-snapshot.sh projects it as
# board rows' choices. Like the kind, choices live and die with the reason:
# a re-hold that passes none drops them, and an unhold clears them. A default
# no longer takes `;`, so the grammar stays unambiguous. `choices` sets or
# replaces the choices on a call already held for the captain, keeping its
# reason, kind, default, release time and date: it re-holds through `hold`,
# which refuses when the row was answered, released or re-held since it read it.
# `defer` keeps a call's choices through the re-hold.
# `release-due` is the release half. For every open row still held for the
# captain whose stored reason carries a reversible default whose release time
# has passed (FM_CAPTAIN_HOLD_NOW overrides now, as for `hold`), it records the
# release as the decision of record - a resolution block whose mode is
# `defaulted` and whose label is `Default release:`, so it never reads as the
# captain's own words - then closes a captain-kind question row or lifts the
# hold on any other work row so it resumes on the default, publishes the
# matching parent-channel resolution in a secondmate home, and prints one line
# `released by default: <id> <option>`. bin/fm-watch.sh runs it on its own
# hourly tick and turns each printed line into a durable `check:` wake. A row it
# cannot read or close is reported on stderr and left held, so a failure delays
# a release rather than inventing one.
#
# `answer` records the captain's exact words and resolves the call in the same
# act. It requires a non-empty captain decision file of at most 8192 bytes and
# writes a resolution block while preserving the leading hold-set stamp until
# the close succeeds (the previous body is preserved and archived through
# tasks-axi --archive-body). It closes a question with `tasks-axi done` - or,
# with `--release`, lifts the hold with `tasks-axi unhold` so a captain-gated
# WORK item resumes without closing - and restores resolution-first body
# ordering. An exact retry also completes unfinished ordering normalization and
# is idempotent only when its requested close mode
# matches the newest record; a changed decision or a mode mismatch is rejected.
# A re-held task may record a new answer on top. On a task already closed outside this script,
# `answer` records the missing resolution block (the old `repair` path) only
# when the task still carries the captain-hold provenance tasks-axi preserves
# through a close, so an ordinary finished task cannot be dressed up as an
# answered captain call. A hold that expired by date (`--until` in the past) is
# still answerable: the surviving hold annotations, not tasks-axi's live
# `held:` bit, prove the captain owned it.
#
# `defer` records the captain's dated deferral of an open captain hold: the
# exact words of the decision file go on a `Captain deferred:` body block (the
# previous body archived), and the task is re-held with `hold --until` that
# date, keeping its kind (a reversible default is dropped, because the captain
# has engaged) and its reason. The re-hold comes first and the words are
# recorded once it stands, so a call closed in between never carries a deferral
# it did not get. A date may be today in the captain's own time zone, so only a
# date before yesterday in UTC (FM_CAPTAIN_HOLD_NOW overrides now) is refused.
# A deferral already recorded is a no-op whatever its date - when it is applied,
# or when a newer deferral has replaced it, so a replayed older answer never
# rolls the date back. It never closes or releases anything.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer resolves its matching captain-held task" is a single
# capability, owned here and nowhere else. `answers` reads
# `<task-id>\t<answer>\t<label>[\t<mode>]` lines on stdin and resolves each named
# task through the very same `answer` path above, so every guard applies
# identically no matter which channel the answer arrived on. The key IS the
# task id - no identity arithmetic. The optional fourth field selects the close:
# empty or `done` completes the task, `release` lifts the hold so held work
# resumes, and `until=YYYY-MM-DD` is the captain's deferral, recorded through
# `defer` above (reported `deferred:`) so a "later" answer never closes the
# call; anything else is skipped. A key that names no task, a task that is
# not held for the captain, or a task already closed is reported as `skipped:`
# and feeds nothing. A replayed delivery whose answer digest and requested
# close mode both match the newest record is reported `closed:` and is a no-op;
# a mode mismatch is skipped. The command exits nonzero when any key was
# skipped. `--source` is provenance text recorded in the
# durable decision, never a behavior switch: this command has no per-channel
# branch and no knowledge of chat, review decks, or any transport.
# Legacy input: an optional positional origin (or a stored concrete-origin
# binding) makes a key that names no task fall back to the old
# `<origin>-decision-<key>` identity, so an in-flight pre-collapse channel
# keeps closing its rows; `--any-origin` and the stored `(any)` marker mean
# what an absent origin means and are accepted for the same reason.
#
# RECONCILE IS RESERVED AT THIS INTAKE, NOT FILTERED IN A CHANNEL.
# The exact answer value `reconcile` means "go re-check reality", never "the
# captain answered". `answers` matches it before it reads the close mode,
# visibly refuses it, and never passes it to `answer`, so no channel and no
# card-declared mode can turn it into a close, release, or request. The exact
# value `later` is the captain's deferral, so without an `until=` mode it is
# refused the same visible way and the call stays held. A separate
# `reconcile-requests` intake verifies a captured source's binding before it
# records a durable request under `state/reconcile-requests/`.
#
# `reconcile` is the verify-then-decide half. Both outcomes require the pending
# request created by the captain's board selection. `close` is the moot outcome:
# it requires the evidence that made the call moot, writes a `reconciled` resolution record
# under a `Reconciliation evidence:` label so it can never read as the
# captain's words, and closes the task. `note` is the still-active outcome: it
# appends one dated `Captain hold reconciled:` note and leaves the hold in
# place. A normal answer also retires the request because the call is settled.
# `list` is the read-only enumeration.
# docs/captain-hold-lifecycle.md owns the semantics.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines
# and pipe them here. It must never map keys to tasks, build decision records,
# choose a close mode beyond what its card declared, or close anything itself.
#
# `bind`, `unbind`, and `binding` record that a captured-answer SOURCE feeds
# this intake, for any channel whose answers arrive detached from their origin
# (a process-event source id, for example). The binding is a private record
# under `state/decision-bindings/`; a source with no binding feeds nothing, so
# this whole path is opt-in per source and an unbound source behaves as if it
# did not exist. `bind` deliberately does not require the source to exist yet,
# so a channel can be bound BEFORE it is armed. The optional second argument
# exists only for legacy pre-collapse records and callers: a concrete origin is
# stored verbatim and used as the composition fallback above, and
# `--any-origin` stores the same `(any)` marker a plain `bind <source-id>`
# stores. `binding` prints the stored value verbatim and `answers` accepts it,
# so the process-event runner's feed seam is unchanged.
#
# `board-link` records a board's new link on every still-open captain call in
# an origin's attested inventory, as one `Captain hold board: <url>` line plus
# the origin and time, once per link. Scout teardown calls it with each board
# it hands over to firstmate (bin/fm-procevent.sh `adopt-task`), so the link
# outlives the scout's status log whether or not it changed; a closed call is
# skipped, and a call whose state cannot be read fails the command.
#
# `complete` is the shared investigation and visual-review completion gate.
# It attests, in the origin task's metadata, the reviewed inventory of
# captain-held tasks that carry the origin's unresolved captain calls.
# `--none` is an explicit semantic attestation that the just-reviewed surface
# has no unresolved captain call, and is refused while the origin still has an
# open keyed status decision. With a non-empty inventory, every listed task is
# verified durable (captain-held, or carrying a recorded resolution),
# is never the origin itself, and, when `hold --origin` recorded one, was held
# for this origin; a hold with no recorded origin is accepted on durability
# alone and named in the output,
# the inventory is unioned idempotently into the metadata, and every still-open
# keyed status decision is transferred to its durable owner with a
# `captain-held [key=...]` status close naming the inventory. Later review
# passes may add ids. A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still satisfy the same durability and origin checks as `complete`,
# and no keyed status decision may be open.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by fm-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task. On the
# Beads backend an attested legacy markdown id that resolves to no task is
# accepted through the migrated row fm-hold-migration produced, found by the
# authoritative evidence first: a row whose notes carry the marker line
# "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>". Only when no row carries that line is the legacy id tried under
# the configured beads prefix, and that name-only guess is accepted solely for
# a single row still held for the captain; two such rows refuse rather than
# attest, and `complete` names each prefix-resolved row beside its attested
# legacy id so the guess stays auditable.
#
# `open` is the read-only predicate a mechanical closer asks before it may
# retire a task's row: is this task still an open captain call? Exit 0 means it
# is (not Done, hold kind captain), 1 means it is not, and 2 means the answer
# could not be established, so a caller that must never close a live call can
# treat "cannot tell" as its own case instead of as a no. With
# `--distinguish-absent`, an absent local task returns 3 instead of 1; a home
# with no backlog file counts as absent, because it records no captain calls.
# It prints nothing on these predicate results and mutates nothing, unless
# `--identity` asks it to print this call's
# LIFECYCLE identity, which it does on an exit 0 only. That identity - the
# hold-set stamp and the count of recorded answers - is what distinguishes two
# successive calls on one task id: re-holding released work starts a new
# lifecycle without necessarily touching the task's status log, so a consumer
# that bounds repeated work per call cannot use the task id alone.
# bin/fm-teardown.sh asks it before its automatic
# backlog close and, on 0, returns the row to Queued with its deliverable
# recorded instead (bin/fm-backlog-transition-lib.sh owns that transition), so
# holding the very work item a question gates is safe; only `answer` with the
# captain's words or evidence-backed `reconcile close` closes the call.
# bin/fm-watch.sh asks it when an ordinary
# crew task reaches a due stale alarm - its open backlog hold need not appear in
# the task's last status line - and on a 0 bounds repeated alarms from new pane
# hashes for the decision.
#
# `diverged` is the read-only guard over the seam between the two records of
# one captain call. See "record divergence" beside command_diverged below.
#
# Resolution records: the block written into the body names this script, the
# decision digest, and a `Resolution mode:` of answered, released, repaired,
# reconciled, or defaulted. Records written by the retired fm-decision-hold.sh (routed,
# declined, answered, repaired) are recognized everywhere a record is read, so
# nothing already closed needs rewriting.
#
# Parent channel: inside a secondmate home a task held for the captain, and its
# answer, are captain-facing facts the moment they are recorded, so `hold`
# publishes `needs-decision [key=captain-hold-<task>-<n>]` and `answer` (and
# `answers`) the matching `resolved` line on the parent channel through
# bin/fm-parent-channel-lib.sh, whether or not the mate model appends anything.
# <n> is the count of resolution records the body already carries plus one, so
# a released and re-held task opens and closes a distinct parent decision with
# no new persisted state, and an exact retry republishes the same line, which
# the channel deduplicates. A main home has no channel and publishes nothing.
# The hold or answer is already durable in the backlog, so a channel that
# cannot be written is reported as `actionable:` on stderr rather than undoing
# the record; bin/fm-inactive-reconcile.sh's diagnostics name a broken binding.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-backlog-owner-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-owner-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

PARENT_HOLD_PUBLISHED=0
publish_parent_hold() {  # <task-id> <occurrence> <verb> <note>
  local id=$1 occurrence=$2 verb=$3 note=$4 rc=0
  PARENT_HOLD_PUBLISHED=0
  fm_parent_channel_report "$FM_HOME" "$STATE" \
    "$verb [key=captain-hold-$id-$occurrence]: captain hold $id: $(fm_parent_channel_clean_note "$note")" || rc=$?
  case "$rc" in
    0|1) PARENT_HOLD_PUBLISHED=1 ;;
    *) printf 'actionable: task %s is held for the captain in this home but that did not reach the parent channel (rc=%s)\n' "$id" "$rc" >&2 ;;
  esac
}

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
CAPTAIN_CONTROL_LOCK=
CAPTAIN_CONTROL_LOCK_HELD=0
CAPTAIN_META_TMP=
captain_hold_cleanup() {
  [ -z "$CAPTAIN_META_TMP" ] || rm -f "$CAPTAIN_META_TMP" 2>/dev/null || true
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
  fi
  if [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_CONTROL_LOCK" || true
    CAPTAIN_CONTROL_LOCK_HELD=0
  fi
}
trap captain_hold_cleanup EXIT

fail() {
  printf 'fm-captain-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

acquire_task_control_lock() {  # <task-id>
  CAPTAIN_CONTROL_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=1
}

release_task_control_lock() {
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=0
  CAPTAIN_CONTROL_LOCK=
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

# The legacy derived identity older installs minted for a captain call.
# Kept only to resolve pre-collapse rows, metadata entries, and channel keys.
legacy_hold_id() {  # <origin-id> <key>
  printf '%s-decision-%s' "$1" "$2"
}

# The legacy any-origin binding marker. Slug validation rejects parentheses, so
# no real origin id or task id can collide with it.
BINDING_ANY='(any)'

DECISION_TEXT=''
DECISION_DIGEST=''

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

# Mutations address the configured data directory's backlog from its root, the
# way bin/fm-backlog-transition-lib.sh addresses every transition, so a home
# with a relocated data directory keeps one backlog. The explicit --file file
# belongs to the markdown backend only; a non-markdown backend is addressed by
# the root's own tasks-axi configuration, exactly like the transition library's
# mutate path.
tasks_axi() {
  local data file root backend
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

# Read one row into TASK_SHOW_OUTPUT; a non-zero return means the row is
# absent. A read that could not finish inside its bound is NOT absence, and
# every caller below would otherwise spend it as one - minting a duplicate task,
# skipping a keyed answer, or reporting a task that exists as missing. So the
# bound's own status stops the command instead, loudly and by name, and it
# leaves 124 intact rather than collapsing to fail's 1 so a caller running this
# inside a command substitution can still tell a wedged backend from a
# genuinely unknown id.
TASK_SHOW_OUTPUT=
task_show() {  # <id>; sets TASK_SHOW_OUTPUT
  local data status=0 reason
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  TASK_SHOW_OUTPUT=$(fm_backlog_row_show "$data" "$1" --full 2>/dev/null) || status=$?
  if [ "$status" -eq 124 ]; then
    reason=${TASK_SHOW_OUTPUT%%$'\n'*}
    printf 'fm-captain-hold: %s\n' \
      "${reason:-tasks-axi show $1 exceeded its backlog read bound}" >&2
    exit 124
  fi
  return "$status"
}

# Read one row into `show`, failing with <absence-message> only when the read
# genuinely failed; a read-bound hit (124) stops the command by name instead.
# task_show must be called in THIS shell, not inside a command substitution:
# it carries the row in TASK_SHOW_OUTPUT, which a subshell cannot hand back.
task_show_or_fail() {  # <id> <absence-message>; sets show
  task_show "$1" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $1"
    fail "$2"
  }
  show=$TASK_SHOW_OUTPUT
}

# A markdown home's done_keep retention moves a closed row out of the backlog
# into its archive file (the [markdown] `archive` key of .tasks.toml, default
# done-archive.md beside the backlog), where tasks-axi show no longer finds it.
# An answered captain call stays answered after that move, so the completion
# gate reads the newest archived copy instead of calling the call absent. The
# copy is re-read through tasks-axi from a one-row scratch backlog, so its
# fields arrive exactly as a live read prints them; only a done row qualifies.
# The read carries the same bound as task_show and stops the command by name
# when it is hit, because a wedged read is not absence.
archived_task_show() {  # <id>; sets TASK_SHOW_OUTPUT
  local id=$1 data root backend file archive scratch sources=() status=0 secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  [ "$backend" = markdown ] || return 1
  file=$(fm_backlog_file "$data") || return 1
  archive=$(LC_ALL=C awk '
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) { inmd = (line ~ /\[markdown\]/); next }
      if (inmd && line ~ /^[[:space:]]*archive[[:space:]]*=/) {
        sub(/^[^=]*=[[:space:]]*/, "", line); sub(/[[:space:]]+$/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        print line; exit
      }
    }
  ' "$root/.tasks.toml" 2>/dev/null)
  case "$archive" in
    '') archive="${file%/*}/done-archive.md" ;;
    /*) ;;
    *) archive="$root/$archive" ;;
  esac
  [ ! -f "$file" ] || sources+=("$file")
  [ ! -f "$archive" ] || sources+=("$archive")
  [ "${#sources[@]}" -gt 0 ] || return 1
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-hold-archived.XXXXXX") || return 1
  # The newest archived copy of the row: the last `- [x] <id> -` entry under any
  # `## Archived` heading, with its indented continuation lines.
  { printf '# Backlog\n\n## Done\n'; FM_ARCHIVED_ID=$id LC_ALL=C awk '
    FNR == 1 { archived = 0; grab = 0 }
    /^## / { archived = ($0 ~ /^## Archived/); grab = 0; next }
    /^- \[/ { grab = 0 }
    archived && index($0, "- [x] " ENVIRON["FM_ARCHIVED_ID"] " - ") == 1 { block = ""; grab = 1 }
    grab { block = block $0 "\n" }
    END { printf "%s", block }
  ' "${sources[@]}" 2>/dev/null; } > "$scratch/backlog.md"
  if grep -q '^- \[x\] ' "$scratch/backlog.md"; then
    TASK_SHOW_OUTPUT=$(cd "$scratch" && fm_run_timed "$secs" tasks-axi show "$id" --full --file "$scratch/backlog.md" 2>/dev/null) || status=$?
  else
    status=1
  fi
  rm -rf -- "$scratch"
  if [ "$status" -eq 124 ]; then
    printf 'fm-captain-hold: tasks-axi show %s exceeded its %ss archive read bound\n' "$id" "$secs" >&2
    exit 124
  fi
  [ "$status" -eq 0 ] && [ "$(show_field "$TASK_SHOW_OUTPUT" state)" = "done" ]
}

# task_show, falling back to the archived copy only when the live backlog
# reports the row NOT_FOUND; any other read failure keeps task_show's verdict.
task_show_or_archived() {  # <id>; sets TASK_SHOW_OUTPUT
  task_show "$1" && return 0
  printf '%s\n' "$TASK_SHOW_OUTPUT" | grep -q '^code: NOT_FOUND$' || return 1
  archived_task_show "$1"
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# A shown scalar field arrives as a JSON-encoded bare string, which decode_json
# accepts only where the installed JSON::PP defaults allow_nonref on. Older
# libraries default it off and reject the whole value as "must be object or
# array", so ask for it explicitly rather than inheriting the local default.
decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
show_field_value() {  # <show-output> <field>
  local value
  value=$(decode_shown_value "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1"
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# A resolution record written by this script or by the retired
# fm-decision-hold.sh. Both carry the same leader-then-captain-decision shape.
body_has_resolution_record() {  # <task-body>
  case "$1" in
    *"Resolution recorded by fm-captain-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-decision-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Reconciliation evidence:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Default release:"*) return 0 ;;
  esac
  return 1
}

# The recorded decision digest of either record format, from the show-escaped
# body (multi-line bodies print as one quoted line with \n escapes). Records
# are prepended, so the first match is the newest record.
recorded_decision_digest() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Decision digest: "*) rest=${rest#*"Decision digest: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

# How many resolution records the shown body carries, in either record format.
resolution_record_count() {  # <task-body>
  local body
  body=$(decode_shown_value "$1") || return 1
  printf '%s\n' "$body" \
    | grep -Ec '^Resolution recorded by fm-(captain|decision)-hold\.$' || true
}

# The newest record's `Resolution mode:` value; empty for a record predating it.
recorded_resolution_mode() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Resolution mode: "*) rest=${rest#*"Resolution mode: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

closed_answer_replay_mode_compatible() {  # <mode> <task-body>
  case "$1" in
    answered|repaired|routed) return 0 ;;
  esac
  return 1
}

# The record's label is what keeps an evidence-backed reconciliation from
# reading as the captain's own words. `reconciled` closes a call that went moot
# and carries verified evidence, `defaulted` records a reversible default that
# released itself, and every other mode carries what the captain said.
resolution_block() {  # <mode>
  local label='Captain decision:'
  case "$1" in
    reconciled) label='Reconciliation evidence:' ;;
    defaulted) label='Default release:' ;;
  esac
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\n\n%s\n%s\n' \
    "$DECISION_DIGEST" "$1" "$label" "$DECISION_TEXT"
}

# Durable state of one captain call: an active captain hold (annotations
# surviving even when a date gate has expired) or a recorded captain answer.
verify_hold_durable() {  # <task-id>
  local id=$1 show state hold_kind body
  task_show_or_archived "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if body_has_resolution_record "$body"; then
    return 0
  fi
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  fail "captain-held task $id is neither held for the captain nor closed with a recorded captain answer"
}

# --- migrated legacy-id resolution on the Beads backend ---------------------
#
# A home that moved its backlog from markdown to Beads no longer carries the
# legacy hold ids a scout report attested: the migration rehomed every held
# row under a prefixed fm- id and recorded its markdown identity in the row's
# notes as "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>" (fm-hold-migration wrote the dated form on 2026-09-04). When an
# attested legacy id resolves to no task, the beads backend accepts the row the
# migration produced, found by scanning the configured graph's notes for either
# form of that marker line, and only when no row carries the marker by
# prepending the configured prefix to the legacy id - a name-only guess, so it
# is accepted solely for a row still held for the captain and only when it is
# the single such row. A markdown home keeps its legacy rows verbatim, so its
# exact-id resolution is unchanged.

CAPTAIN_MIGRATION_SCAN_LOADED=0
CAPTAIN_MIGRATION_SCAN_JSON=
NL_SEP=$'\n'

# Section-aware [beads] extraction from a .tasks.toml: only keys inside the
# [beads] section, comments stripped. Prints "<key> <value>" lines.
captain_beads_toml_entries() {  # <toml-file>
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { inbeads = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { inbeads = (line == "[beads]"); next }
      if (!inbeads) next
      if (line ~ /^(prefix|path|binary)[[:space:]]*=/) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "%s %s\n", key, line
      }
    }
  ' "$1"
}

captain_beads_setting() {  # <entries-output> <setting>
  printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1
}

# Read the configured beads graph's row listing for a migration-note scan.
# The listing is deliberately re-read per unresolvable key: the cache below
# lives and dies with the command-substitution subshell every resolve_entry
# call site runs in, so it cannot persist across keys - bounded by a scout
# report's handful of attested ids. Returns 0 when the listing loads, and 2
# with the reason on stderr when the graph cannot be read.
captain_migration_scan_load() {  # <resolved-data-dir>
  local data=$1 root entries bd_bin bd_path backend
  [ "$CAPTAIN_MIGRATION_SCAN_LOADED" = 1 ] && return 0
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the configured data directory cannot be resolved for a migration scan: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" != beads ]; then
    CAPTAIN_MIGRATION_SCAN_LOADED=1
    return 0
  fi
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  bd_bin=$(captain_beads_setting "$entries" binary)
  bd_path=$(captain_beads_setting "$entries" path)
  bd_bin=${bd_bin:-bd}
  if [ -z "$bd_path" ]; then
    printf 'fm-captain-hold: the beads backend carries no graph path in %s, so a migrated hold cannot be found\n' "$root/.tasks.toml" >&2
    return 2
  fi
  # A relative [beads] path resolves against the backlog root, the same rule
  # every other .tasks.toml path consumer uses, never against the process CWD.
  case "$bd_path" in
    /*) ;;
    *) bd_path="$root/$bd_path" ;;
  esac
  command -v "$bd_bin" >/dev/null 2>&1 || {
    printf 'fm-captain-hold: the beads binary %s is not on PATH, so a migrated hold cannot be found\n' "$bd_bin" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-captain-hold: jq is required to scan the beads graph for a migrated hold\n' >&2
    return 2
  }
  local bd_err
  bd_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-bd.XXXXXX") || {
    printf 'fm-captain-hold: cannot stage the beads graph read diagnostics\n' >&2
    return 2
  }
  if ! CAPTAIN_MIGRATION_SCAN_JSON=$(BEADS_DIR="$bd_path" "$bd_bin" list --all --json 2>"$bd_err"); then
    printf 'fm-captain-hold: reading the beads graph at %s failed (%s), so a migrated hold cannot be found\n' \
      "$bd_path" "$(sanitize_field "$(head -c 200 "$bd_err" | tr '\n' ' ')")" >&2
    rm -f "$bd_err"
    return 2
  fi
  rm -f "$bd_err"
  CAPTAIN_MIGRATION_SCAN_LOADED=1
  return 0
}

# Resolve one attested legacy id to the migrated row that carries it on the
# beads backend. Prints "<row id> <how>" and returns 0 when exactly one
# migration matches, returns 1 when none does, and returns 2 with the reason on
# stderr when the scan itself cannot run or is ambiguous. The marker note is the
# authoritative evidence and is scanned first; the bare configured prefix is a
# guess, so it only runs when no marker line matches any identity and it accepts
# a row solely when that row is itself still held for the captain.
resolve_migrated_entry() {  # <origin-or-empty> <entry>
  local origin=$1 entry=$2 data root entries prefix derived show backend
  local candidate candidate_matches prefixed matches count prefixed_matches prefixed_count
  data=$(fm_backlog_data_absolute "$DATA") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  [ "$backend" = beads ] || return 1
  # Every identity this entry could have been migrated under: the raw entry,
  # and - for a pre-collapse channel key - the derived legacy identity its
  # origin would have minted, because fm-hold-migration recorded the DERIVED
  # id in each migrated row's marker note.
  CAPTAIN_MIGRATION_IDENTITIES=$entry
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    derived=$(legacy_hold_id "$origin" "$entry")
    if [ "$derived" != "$entry" ]; then
      CAPTAIN_MIGRATION_IDENTITIES="$CAPTAIN_MIGRATION_IDENTITIES $derived"
    fi
  fi
  captain_migration_scan_load "$data" || return 2
  matches=
  if [ -n "$CAPTAIN_MIGRATION_SCAN_JSON" ]; then
    for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
      candidate_matches=$(printf '%s\n' "$CAPTAIN_MIGRATION_SCAN_JSON" | jq -r \
        --arg exact "migrated from data/backlog.md id $candidate" \
        --arg dated "migrated from data/backlog.md id $candidate on " \
        '.[] | select(((.notes // "") | split("\n")) | any(. == $exact or startswith($dated))) | .id' 2>/dev/null) || {
        printf 'fm-captain-hold: the beads graph scan for the migrated hold of %s could not be parsed\n' "$candidate" >&2
        return 2
      }
      matches="${matches}${matches:+$NL_SEP}${candidate_matches}"
    done
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
      0) : ;;
      1) printf '%s migrated-note' "$(printf '%s\n' "$matches" | sed '/^$/d' | sed -n 1p)"; return 0 ;;
      *)
        printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s rows carry its marker line (identities tried: %s)\n' \
          "$entry" "$count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
        return 2
        ;;
    esac
  fi
  # No marker line anywhere: a mechanical migration keeps the legacy id under
  # the configured prefix, but that name alone is evidence of nothing, so only
  # a row still held for the captain - and only one of them - is accepted.
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  prefix=$(captain_beads_setting "$entries" prefix)
  [ -n "$prefix" ] || return 1
  prefixed_matches=
  for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
    case "$prefix" in
      *-) prefixed="$prefix$candidate" ;;
      *) prefixed="$prefix-$candidate" ;;
    esac
    # Same shell rule as task_show_or_fail: the row is read out of
    # TASK_SHOW_OUTPUT, so the read cannot sit inside a command substitution.
    task_show "$prefixed" 2>/dev/null || {
      [ "$?" -ne 124 ] || return 124
      continue
    }
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
    prefixed_matches="${prefixed_matches}${prefixed_matches:+$NL_SEP}$prefixed"
  done
  prefixed_count=$(printf '%s\n' "$prefixed_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$prefixed_count" in
    0) return 1 ;;
    1) printf '%s migrated-prefix' "$prefixed_matches"; return 0 ;;
  esac
  printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s captain-held rows carry the configured prefix (identities tried: %s)\n' \
    "$entry" "$prefixed_count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
  return 2
}

# Resolve one inventory entry or channel key to the task that carries it: the
# exact task id when it exists, else the legacy derived identity, else - on the
# beads backend - the migrated row the markdown-to-beads hold migration wrote,
# else - on the markdown backend - the exact or legacy row retention archived.
# Prints "<resolved id> <how>", where <how> is exact, legacy, migrated-note,
# migrated-prefix, archived or archived-legacy, so a caller can record which
# evidence carried the attestation.
resolve_entry() {  # <origin-or-empty> <entry>; prints "<id> <how>" or fails
  local origin=$1 entry=$2 legacy migrated rc
  if task_show "$entry"; then
    printf '%s exact' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if task_show "$legacy"; then
      printf '%s legacy' "$legacy"
      return 0
    fi
  fi
  rc=0
  migrated=$(resolve_migrated_entry "$origin" "$entry") || rc=$?
  case "$rc" in
    0) printf '%s' "$migrated"; return 0 ;;
    2) return 2 ;;
    124) return 124 ;;
  esac
  if archived_task_show "$entry"; then
    printf '%s archived' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if archived_task_show "$legacy"; then
      printf '%s archived-legacy' "$legacy"
      return 0
    fi
    fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA); the nearest legacy identity $legacy also resolves to nothing"
  fi
  fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA)"
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}

write_hold_set_stamp() {  # <task-id> <shown-body> <timestamp> <preserve-existing-0-or-1>
  local id=$1 body=$2 hold_set=$3 preserve=$4 existing new_body tmp
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  existing=$(body_hold_set_timestamp "$body")
  if [ "$preserve" = 1 ] && [ -n "$existing" ]; then
    return 0
  fi
  if [ -n "$existing" ]; then
    body=${body#"Captain hold set: $existing"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
  fi
  new_body=$(printf 'Captain hold set: %s' "$hold_set")
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-stamp.XXXXXX") \
    || fail "cannot stage the hold-set stamp"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold-set stamp for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold-set stamp on $id"
  fi
  rm -f -- "$tmp"
}

# The origin a hold was recorded for lives in the held task's own body, on a
# line of its own, so `complete` can tell a call held for this origin from one
# held for another. Omitting --origin leaves any existing association intact.
body_hold_origin() {  # <decoded-task-body>
  printf '%s\n' "$1" | sed -n 's/^Captain hold origin: \(.*\)$/\1/p' | head -1
}

task_identity() {
  local id=$1
  if task_show "$id"; then
    id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
    validate_slug backend-task-id "$id"
  elif ! printf '%s\n' "$TASK_SHOW_OUTPUT" | grep -q '^code: NOT_FOUND$'; then
    fail "could not resolve the backend identity of $id"
  fi
  printf '%s' "$id"
}

write_hold_origin() {  # <task-id> <shown-body> <origin-or-empty>
  local id=$1 body=$2 origin=$3 stamp rest new_body tmp
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  stamp=$(printf '%s\n' "$body" | sed -n 1p)
  [ -n "$(body_hold_set_timestamp "$body")" ] \
    || fail "task $id lost its hold-set stamp before its origin was recorded"
  rest=$(printf '%s\n' "$body" | sed 1d | awk '!/^Captain hold origin: /' \
    | awk 'NF || started { started = 1; print }')
  new_body=$stamp
  if [ -n "$origin" ]; then
    new_body=$(printf '%s\nCaptain hold origin: %s' "$stamp" "$origin")
  fi
  if [ -n "$rest" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$rest")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-origin.XXXXXX") \
    || fail "cannot stage the hold origin"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold origin for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold origin on $id"
  fi
  rm -f -- "$tmp"
}

refuse_self_inventory() {
  local origin=$1 entry=$2 meta="$STATE/$1.meta"
  if list_has_key "$(meta_value "$meta" decision_keys)" "$entry"; then
    fail "origin $origin cannot be its own captain-call inventory entry; historical decision_keys in $meta still contains $entry; hold a separate captain task with --origin $origin, replace only $entry in the final decision_keys= line with that task id while preserving all other entries, then re-run complete $origin <task-id>"
  fi
  fail "origin $origin cannot be its own captain-call inventory entry; hold a separate captain task for the call and list that task"
}

# Resolve one entry and verify the row it names is durably captain-held. A
# resolution failure that is not the read bound keeps resolve_entry's own
# status - its stderr already named the entry; 124 means the backend never
# answered, which is not the same as an unknown entry and must not be spent
# as absence. The result carries the attestation evidence and whether an
# origin was recorded, so completion can disclose the legacy fallback.
verify_entry_durable() {  # <origin-or-empty> <entry>; prints "<id> <how> <origin-state>"
  local origin=$1 entry=$2 resolved resolve_status=0 id how stored origin_state=unrecorded origin_id stored_id
  # The origin task is never its own captain-call inventory: it is the work the
  # calls were found in, so accepting it would let a refused hold look recorded.
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ] && [ "$entry" = "$origin" ]; then
    refuse_self_inventory "$origin" "$entry"
  fi
  resolved=$(resolve_entry "$origin" "$entry") || resolve_status=$?
  if [ "$resolve_status" -ne 0 ]; then
    [ "$resolve_status" -ne 124 ] \
      || fail "the backlog backend exceeded its read bound resolving $entry"
    exit "$resolve_status"
  fi
  id=${resolved%% *}
  how=${resolved##* }
  verify_hold_durable "$id"
  id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
  validate_slug backend-task-id "$id"
  stored=$(body_hold_origin "$(decode_shown_value "$(show_field "$TASK_SHOW_OUTPUT" body)")")
  origin_id=$origin
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    origin_id=$(task_identity "$origin") || exit $?
    [ "$id" != "$origin_id" ] || refuse_self_inventory "$origin" "$entry"
  fi
  if [ -n "$stored" ]; then
    if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
      stored_id=$(task_identity "$stored") || exit $?
      if [ "$stored_id" != "$origin_id" ]; then
        fail "captain-held task $id was held for origin $stored, not $origin; hold a task for $origin or list the right one"
      fi
    fi
    origin_state=recorded
  fi
  printf '%s %s %s\n' "$id" "$how" "$origin_state"
}

# --- hold kinds and default release (see "HOLD KINDS AND DEFAULT RELEASE") -----

HOLD_DEFAULT_RELEASE_SECS=259200
HOLD_DEFAULT_OPTION_MAX_BYTES=200
HOLD_CHOICE_LABEL_MAX_BYTES=60
HOLD_ASK_MAX_BYTES=200

byte_length() {  # <text>
  printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

trim_text() {  # <text>
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  printf '%s' "${text%"${text##*[![:space:]]}"}"
}

lowercase() {  # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Validate --options/--recommend/--ask (see CHOICES in the header). Sets
# CHOICE_OPTIONS (the trimmed labels joined by |), CHOICE_RECOMMENDED and
# CHOICE_ASK, each empty when absent.
CHOICE_OPTIONS=''
CHOICE_RECOMMENDED=''
CHOICE_ASK=''
validate_hold_choice_args() {  # <kind> <options-given> <options> <recommend-given> <recommend> <ask-given> <ask> <default-given> <default>
  local kind=$1 options_given=$2 options=$3 recommend_given=$4 recommend=$5 ask_given=$6 ask=$7
  local default_given=$8 default_option=$9 label lowered seen='|' count=0 found=0
  local -a labels=()
  CHOICE_OPTIONS=''
  CHOICE_RECOMMENDED=''
  CHOICE_ASK=''
  if [ "$options_given" = 1 ] || [ "$recommend_given" = 1 ] || [ "$ask_given" = 1 ]; then
    [ -n "$kind" ] || fail "--options, --recommend and --ask ride on the hold-kind prefix, so they require --kind"
  fi
  [ "$recommend_given" != 1 ] || [ "$options_given" = 1 ] || fail "--recommend requires --options"
  if [ "$options_given" = 1 ]; then
    validate_one_line options "$options"
    IFS='|' read -r -a labels <<< "$options"
    case "$options" in *'|') labels+=('') ;; esac
    for label in "${labels[@]}"; do
      label=$(trim_text "$label")
      [ -n "$label" ] || fail "--options must not hold an empty choice"
      case "$label" in
        *']'*|*';'*) fail "a choice must not contain ] or ;: $label" ;;
      esac
      [ "$(byte_length "$label")" -le "$HOLD_CHOICE_LABEL_MAX_BYTES" ] \
        || fail "a choice must be at most $HOLD_CHOICE_LABEL_MAX_BYTES bytes: $label"
      lowered=$(lowercase "$label")
      case "$lowered" in
        later|reconcile) fail "a choice must not be the reserved answer $lowered" ;;
      esac
      case "$seen" in
        *"|$lowered|"*) fail "--options repeats a choice: $label" ;;
      esac
      seen="$seen$lowered|"
      count=$((count + 1))
      CHOICE_OPTIONS="${CHOICE_OPTIONS:+$CHOICE_OPTIONS|}$label"
    done
    [ "$count" -ge 2 ] && [ "$count" -le 3 ] || fail "--options takes two or three choices split on |"
    if [ "$default_given" = 1 ]; then
      [ "$recommend_given" != 1 ] || [ "$(trim_text "$recommend")" = "$default_option" ] \
        || fail "a reversible default is its recommendation, so --recommend must equal --default"
      recommend=$default_option
    else
      [ "$recommend_given" = 1 ] || fail "--options needs --recommend naming the recommended choice"
      recommend=$(trim_text "$recommend")
    fi
    for label in "${labels[@]}"; do
      [ "$(trim_text "$label")" != "$recommend" ] || found=1
    done
    [ "$found" = 1 ] || fail "the recommended choice must be one of --options: $recommend"
    CHOICE_RECOMMENDED=$recommend
  fi
  if [ "$ask_given" = 1 ]; then
    ask=$(trim_text "$ask")
    validate_one_line ask "$ask"
    case "$ask" in *']'*|*';'*) fail "--ask must not contain ] or ;" ;; esac
    [ "$(byte_length "$ask")" -le "$HOLD_ASK_MAX_BYTES" ] \
      || fail "--ask must be at most $HOLD_ASK_MAX_BYTES bytes"
    CHOICE_ASK=$ask
  fi
}

# The prefix suffix that records validated choices, empty when there are none.
hold_choice_suffix() {
  local suffix=''
  [ -z "$CHOICE_OPTIONS" ] || suffix="; options: $CHOICE_OPTIONS; recommended: $CHOICE_RECOMMENDED"
  [ -z "$CHOICE_ASK" ] || suffix="$suffix; ask: $CHOICE_ASK"
  printf '%s' "$suffix"
}

validate_hold_kind_args() {  # <kind> <default-given> <default-option> <reason> <no-default> <until>
  local kind=$1 given=$2 option=$3 reason=$4 no_default=$5 until=$6
  case "$kind" in
    ''|reversible|arjun-only) : ;;
    *) fail "--kind must be reversible or arjun-only: $kind" ;;
  esac
  if [ "$no_default" = 1 ]; then
    [ "$given" != 1 ] || fail "pass --default or --no-default, not both"
    [ "$kind" = reversible ] || fail "--no-default requires --kind reversible"
  elif [ "$kind" = reversible ] && [ "$given" != 1 ] && [ -z "$until" ]; then
    fail "a reversible hold takes --default <option> so it releases itself after 72 hours; pass --until when the captain deferred it, or --no-default when no option is safe to apply unasked"
  fi
  if [ "$given" = 1 ]; then
    [ "$kind" != arjun-only ] \
      || fail "an arjun-only hold never releases itself, so it takes no --default; put the recommendation in the reason"
    [ "$kind" = reversible ] || fail "--default requires --kind reversible"
    [ -z "$until" ] || fail "a call the captain deferred with --until takes no --default"
    validate_one_line default "$option"
    case "$option" in
      *']'*|*';'*) fail "--default must not contain ] or ;" ;;
    esac
    [ "$(byte_length "$option")" -le "$HOLD_DEFAULT_OPTION_MAX_BYTES" ] \
      || fail "--default must be at most $HOLD_DEFAULT_OPTION_MAX_BYTES bytes"
  fi
  case "$reason" in
    '[reversible]'*|'[reversible;'*|'[arjun-only]'*|'[arjun-only;'*)
      fail "the reason must not begin with a hold-kind prefix; pass --kind and --default instead"
      ;;
  esac
}

# Parse the kind prefix of a decoded reason. Sets HOLD_DECISION_KIND
# (reversible, arjun-only, or empty when there is no prefix), HOLD_DEFAULT_OPTION
# and HOLD_RELEASES_AT (both empty unless a reversible default is recorded),
# HOLD_OPTIONS and HOLD_RECOMMENDED (empty unless choices are recorded),
# HOLD_ASK, and HOLD_REASON_REST (the reason after the prefix).
# Returns 1 when the reason carries no kind prefix.
HOLD_DECISION_KIND=''
HOLD_DEFAULT_OPTION=''
HOLD_RELEASES_AT=''
HOLD_OPTIONS=''
HOLD_RECOMMENDED=''
HOLD_ASK=''
HOLD_REASON_REST=''
parse_hold_kind_prefix() {  # <decoded-reason>
  local reason=$1
  local re='^\[(reversible|arjun-only)(; default: ([^]]+); releases ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z))?(; options: ([^];]+); recommended: ([^];]+))?(; ask: ([^]]+))?\] '
  HOLD_DECISION_KIND=''
  HOLD_DEFAULT_OPTION=''
  HOLD_RELEASES_AT=''
  HOLD_OPTIONS=''
  HOLD_RECOMMENDED=''
  HOLD_ASK=''
  HOLD_REASON_REST=$reason
  [[ "$reason" =~ $re ]] || return 1
  # A default rides only on a reversible hold.
  [ -z "${BASH_REMATCH[2]}" ] || [ "${BASH_REMATCH[1]}" = reversible ] || return 1
  HOLD_DECISION_KIND=${BASH_REMATCH[1]}
  HOLD_DEFAULT_OPTION=${BASH_REMATCH[3]}
  HOLD_RELEASES_AT=${BASH_REMATCH[4]}
  HOLD_OPTIONS=${BASH_REMATCH[6]}
  HOLD_RECOMMENDED=${BASH_REMATCH[7]}
  HOLD_ASK=${BASH_REMATCH[9]}
  HOLD_REASON_REST=${reason:${#BASH_REMATCH[0]}}
  return 0
}

epoch_to_utc_iso() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

hold_release_time() {  # <hold-set-utc-iso>
  local start
  start=$(fm_utc_iso_to_epoch "$1") || return 1
  epoch_to_utc_iso $((start + HOLD_DEFAULT_RELEASE_SECS))
}

command_hold() {
  local id=${1:-} title='' reason='' repo='' origin='' until='' show state existing_title body='' hold_kind hold_set occurrence
  local existing_hold_kind='' existing_held='' preserve_hold_set=0 stored_reason previous_origin='' hold_status=0
  local decision_kind='' default_option='' default_given=0 no_default=0 releases='' existing_reason=''
  local options='' options_given=0 recommend='' recommend_given=0 ask='' ask_given=0
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      --kind) shift; decision_kind=${1:-} ;;
      --default) shift; default_option=${1:-}; default_given=1 ;;
      --no-default) no_default=1 ;;
      --options) shift; options=${1:-}; options_given=1 ;;
      --recommend) shift; recommend=${1:-}; recommend_given=1 ;;
      --ask) shift; ask=${1:-}; ask_given=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$reason" ] || fail "reason must not be empty"
  validate_hold_kind_args "$decision_kind" "$default_given" "$default_option" "$reason" "$no_default" "$until"
  validate_hold_choice_args "$decision_kind" "$options_given" "$options" "$recommend_given" "$recommend" \
    "$ask_given" "$ask" "$default_given" "$default_option"
  if [ -n "$origin" ]; then
    validate_slug origin-id "$origin"
  fi
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) fail "--until must be a YYYY-MM-DD date: $until" ;;
    esac
  fi
  hold_set=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$hold_set" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  acquire_task_control_lock "$id"
  require_tasks_axi
  if task_show "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    existing_hold_kind=$(show_field_value "$show" hold_kind)
    existing_held=$(show_field_value "$show" held)
    if [ "$existing_hold_kind" = captain ] && [ "$existing_held" = yes ]; then
      preserve_hold_set=1
      existing_reason=$(fm_hold_reason_decode "$(show_field_value "$show" hold_reason)")
    elif [ -n "${FM_CAPTAIN_HOLD_EXPECT_REASON+set}" ]; then
      fail "task $id is no longer held for the captain"
    fi
    [ -z "${FM_CAPTAIN_HOLD_EXPECT_REASON+set}" ] || [ "$existing_reason" = "$FM_CAPTAIN_HOLD_EXPECT_REASON" ] \
      || fail "task $id was re-held since it was read; read it again"
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
  else
    [ -z "${FM_CAPTAIN_HOLD_EXPECT_REASON+set}" ] || fail "task $id is no longer held for the captain"
    [ -n "$title" ] || fail "--title is required to create task $id"
    validate_one_line title "$title"
    if [ -z "$repo" ] && [ -n "$origin" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    [ -z "$origin" ] || body=$(printf 'Origin: %s' "$origin")
    body=$(fm_backlog_owner_body_with "$body" arjun)
    # tasks-axi add never passes --due. Beads due.required would refuse this
    # create, and captain holds have no due semantics, so waive it for this
    # call only. --kind captain stays metadata; Beads native type is task.
    BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create task $id"
  fi
  # Publish the timestamp before the captain-hold annotation. A concurrent
  # snapshot may see the harmless stamp by itself, but can never see a newly
  # held task without the timestamp that defines this hold lifecycle's age.
  task_show_or_fail "$id" "task $id disappeared before recording its hold-set stamp"
  write_hold_set_stamp "$id" "$(show_field "$show" body)" "$hold_set" "$preserve_hold_set"
  task_show_or_fail "$id" "task $id disappeared while recording its hold-set stamp"
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id did not retain its hold-set stamp"
  if [ -n "$origin" ]; then
    origin=$(task_identity "$origin") || exit $?
    previous_origin=$(body_hold_origin "$(show_field_value "$show" body)")
    write_hold_origin "$id" "$(show_field "$show" body)" "$origin" || exit $?
  fi
  # The kind prefix rides on the stored reason (see the header). An unchanged
  # active reversible default keeps its release time; anything else starts 72h.
  if [ "$default_given" = 1 ]; then
    if parse_hold_kind_prefix "$existing_reason" \
      && [ "$HOLD_DECISION_KIND" = reversible ] && [ "$HOLD_DEFAULT_OPTION" = "$default_option" ]; then
      releases=$HOLD_RELEASES_AT
    else
      releases=$(hold_release_time "$hold_set") || fail "could not compute the default release time"
    fi
    reason="[reversible; default: $default_option; releases $releases$(hold_choice_suffix)] $reason"
  elif [ -n "$decision_kind" ]; then
    reason="[$decision_kind$(hold_choice_suffix)] $reason"
  fi
  # bin/fm-hold-reason-lib.sh owns the storage constraint and reversible encoding.
  stored_reason=$(fm_hold_reason_encode "$reason") || fail "could not encode the hold reason"
  if [ -n "$until" ]; then
    tasks_axi hold "$id" --reason "$stored_reason" --kind captain --until "$until" >/dev/null \
      || hold_status=$?
  else
    tasks_axi hold "$id" --reason "$stored_reason" --kind captain >/dev/null \
      || hold_status=$?
  fi
  if [ "$hold_status" -ne 0 ]; then
    # A refused re-hold must not associate the previous hold or answer with a
    # new origin. Restore the old line verbatim, without resolving it again.
    if [ -n "$origin" ]; then
      write_hold_origin "$id" "$(show_field "$show" body)" "$previous_origin" || exit $?
    fi
    fail "could not hold task $id for the captain"
  fi
  task_show "$id" || fail "task $id disappeared while holding it"
  show=$TASK_SHOW_OUTPUT
  hold_kind=$(show_field_value "$show" hold_kind)
  [ "$hold_kind" = captain ] || fail "task $id did not retain its captain hold"
  write_owner "$id" arjun "$show" || fail "task $id is held for the captain, but its owner could not be recorded; repeat the hold"
  if [ "$OWNER_WRITTEN" = 1 ]; then
    task_show "$id" || fail "task $id disappeared while recording its owner"
    show=$TASK_SHOW_OUTPUT
  fi
  occurrence=$(( $(resolution_record_count "$(show_field "$show" body)") + 1 ))
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id lost its hold-set stamp while being held"
  publish_parent_hold "$id" "$occurrence" needs-decision "$reason"
  printf '%s\n' "$id"
}

# Record a resolution block beneath any leading active hold-set stamp,
# preserving the previous body below it and archiving the pristine original.
# Successful closure removes the stamp to restore resolution-first ordering.
write_resolution_record() {  # <task-id> <mode> <shown-body>
  local id=$1 mode=$2 body=$3 new_body tmp hold_set
  new_body=$(resolution_block "$mode")
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  hold_set=$(body_hold_set_timestamp "$body")
  if [ -n "$hold_set" ]; then
    body=${body#"Captain hold set: $hold_set"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
    new_body=$(printf 'Captain hold set: %s\n\n%s' "$hold_set" "$new_body")
  fi
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-body.XXXXXX") \
    || fail "cannot stage the resolution record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the resolution record for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the captain decision on $id"
  fi
  rm -f -- "$tmp"
}

report_retained_artifact_failure() {  # <task-id> <marker-path>
  printf 'fm-captain-hold: cannot apply the artifact recorded for %s in %s: %s\n' \
    "$1" "$2" "${FM_BACKLOG_TRANSITION_ERROR:-no reason reported}" >&2
}

apply_pending_retained_artifact() {  # <task-id>
  local id=$1 marker label
  local -a args=()
  RETAINED_CLOSE_ARGS=()
  marker=$(fm_backlog_close_marker_path "$STATE" "$id") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  fm_backlog_close_marker_validate "$marker" "$DATA" "$id" "$STATE" \
    || { report_retained_artifact_failure "$id" "$marker"; return 1; }
  [ "$FM_BACKLOG_CLOSE_VALIDATED_MODE" = retain ] || return 0
  args=("${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  case "${args[0]-}" in
    --pr|--report)
      if [ "${args[0]}" = --pr ] && label=$(fm_backlog_pr_note_label "${args[1]-}"); then
        RETAINED_CLOSE_ARGS=(--note "$label ${args[1]}")
        return 0
      fi
      fm_backlog_row_artifact_supported "$id" "${args[@]}" || return 0
      fm_backlog_mutate "$DATA" update "$id" "${args[@]}" \
        || { report_retained_artifact_failure "$id" "$marker"; return 1; }
      ;;
  esac
}

# Record <owner> as the row's owner (see the header) unless it already is.
# A caller holding a fresh read of the row passes it to spare a backend read.
# OWNER_WRITTEN says whether the body changed.
OWNER_WRITTEN=0
write_owner() {  # <task-id> <owner> [<fresh-show-output>]
  local id=$1 owner=$2 show=${3:-} body tmp
  OWNER_WRITTEN=0
  [ -n "$show" ] || task_show_or_fail "$id" "task $id disappeared before recording its owner"
  body=$(show_field_value "$show" body) || return 1
  [ "$(fm_backlog_owner_of_body "$body")" != "$owner" ] || return 0
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-owner.XXXXXX") || return 1
  if ! fm_backlog_owner_body_with "$body" "$owner" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  OWNER_WRITTEN=1
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    tasks_axi unhold "$1" >/dev/null || return 1
    write_owner "$1" fleet
  else
    apply_pending_retained_artifact "$1" || return 1
    tasks_axi "done" "$1" "${RETAINED_CLOSE_ARGS[@]+"${RETAINED_CLOSE_ARGS[@]}"}" >/dev/null
  fi
}

remove_interrupted_answer_stamp() {  # <task-id>
  local id=$1 show body existing tmp
  task_show_or_fail "$id" "task $id disappeared after closing"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the closed body for $id"
  existing=$(body_hold_set_timestamp "$body")
  [ -n "$existing" ] || return 0
  body=${body#"Captain hold set: $existing"}
  case "$body" in
    $'\n\n'*) body=${body#$'\n\n'} ;;
    $'\n'*) body=${body#$'\n'} ;;
  esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-normalize.XXXXXX") \
    || fail "cannot stage the closed body for $id"
  if ! printf '%s\n' "$body" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not restore the resolution record ordering for $id"
  fi
  rm -f -- "$tmp"
}

command_answer() {
  local id=${1:-} decision_file='' release=0 show state hold_kind body outcome recorded_mode occurrence
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --release) release=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  load_decision "$decision_file"
  acquire_task_control_lock "$id"
  require_tasks_axi
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$release" = 1 ]; then outcome=released; else outcome=answered; fi
  # The occurrence the parent line names: the record about to be written is
  # one past those already in the body, and a retry names the newest one.
  occurrence=$(( $(resolution_record_count "$body") + 1 ))

  if [ "$state" = "done" ]; then
    if body_has_resolution_record "$body"; then
      # An exact compatible retry is an idempotent no-op; drift is rejected.
      [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
        || fail "captain-held task $id records a different captain decision"
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      closed_answer_replay_mode_compatible "$recorded_mode" "$body" \
        || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay"
      [ "$release" = 0 ] \
        || fail "task $id records this answer with mode ${recorded_mode:-unknown}; --release cannot reopen a closed task"
      remove_interrupted_answer_stamp "$id"
      if [ "$recorded_mode" = repaired ]; then
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "answered (repaired)"
      else
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) answered
      fi
      printf 'answered: %s\n' "$id"
      return 0
    fi
    [ "$release" = 0 ] || fail "task $id is already closed; --release cannot reopen it"
    # Closed outside this script: record the captain's answer retroactively.
    # tasks-axi keeps hold_kind through a close, so it is the surviving proof
    # this really was the captain's item rather than ordinary finished work.
    [ "$hold_kind" = captain ] \
      || fail "task $id was never held for the captain; nothing to record an answer on"
    write_resolution_record "$id" repaired "$body"
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared while recording the answer"
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field "$show" state)" = "done" ] || fail "recording the answer reopened closed task $id"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)"
    printf 'repaired: %s\n' "$id"
    return 0
  fi

  if [ "$hold_kind" = captain ]; then
    # Actively the captain's item (a date-expired hold keeps its annotations
    # and stays answerable). A matching record means an interrupted close to
    # finish; a different digest is a NEW answer on a re-held task and gets
    # its own record on top. Either way the close mode is the caller's flag,
    # checked against an interrupted close's recorded mode so a retry cannot
    # silently flip a release into a close.
    if body_has_resolution_record "$body" \
      && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      case "$recorded_mode" in
        released) [ "$release" = 1 ] || fail "task $id records this answer as a release; retry with --release" ;;
        answered|routed) [ "$release" = 0 ] || fail "task $id records this answer as a close; retry without --release" ;;
        *) fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay" ;;
      esac
      if ! close_answered "$id" "$release"; then
        fail "could not close answered captain-held task $id"
      fi
      remove_interrupted_answer_stamp "$id"
      publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "$outcome"
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    write_resolution_record "$id" "$outcome" "$body"
    if ! close_answered "$id" "$release"; then
      fail "could not close answered captain-held task $id"
    fi
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared after closing"
    show=$TASK_SHOW_OUTPUT
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "$outcome"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi

  # Not held and not closed: only an already-recorded release replays cleanly.
  if body_has_resolution_record "$body"; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different captain decision with mode ${recorded_mode:-unknown}"
    [ "$recorded_mode" = released ] && [ "$release" = 1 ] \
      || fail "task $id records this answer with mode ${recorded_mode:-unknown}; replay requires matching --release"
    remove_interrupted_answer_stamp "$id"
    # The unhold may have landed before an interrupted owner write.
    write_owner "$id" fleet || fail "task $id is released, but its owner could not be handed back to the fleet; repeat the answer"
    publish_parent_resolution_then_retire "$id" $((occurrence - 1)) released
    printf 'released: %s\n' "$id"
    return 0
  fi
  fail "task $id is not held for the captain; hold it first or name the right task"
}

# Set or replace the choices on a call already held for the captain. The
# re-hold goes through `hold` with FM_CAPTAIN_HOLD_EXPECT_REASON set to the
# reason read here, so it keeps every guard there and refuses, under that
# path's own lock, a row answered, released, closed or re-held since this read.
command_choices() {
  local id=${1:-} show reason hold_until options_given=0 ask_given=0
  local -a pass=() keep=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --options|--recommend|--ask)
        [ "$1" != --options ] || options_given=1
        [ "$1" != --ask ] || ask_given=1
        pass+=("$1" "${2:-}")
        shift
        ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ "$options_given" = 1 ] || fail "choices requires --options"
  require_tasks_axi
  task_show_or_fail "$id" "no task $id"
  [ "$(show_field "$show" state)" != "done" ] || fail "task $id is already closed"
  [ "$(show_field_value "$show" hold_kind)" = captain ] && [ "$(show_field_value "$show" held)" = yes ] \
    || fail "task $id is not held for the captain"
  reason=$(fm_hold_reason_decode "$(show_field_value "$show" hold_reason)")
  parse_hold_kind_prefix "$reason" \
    || fail "task $id carries no hold kind; re-hold it with --kind and the choices"
  hold_until=$(show_field_value "$show" hold_until)
  [ "$hold_until" != - ] || hold_until=''
  keep=(--kind "$HOLD_DECISION_KIND")
  if [ -n "$HOLD_DEFAULT_OPTION" ]; then
    keep+=(--default "$HOLD_DEFAULT_OPTION")
  elif [ -n "$hold_until" ]; then
    keep+=(--until "$hold_until")
  elif [ "$HOLD_DECISION_KIND" = reversible ]; then
    keep+=(--no-default)
  fi
  # An --ask the caller leaves out keeps the recorded one.
  [ "$ask_given" = 1 ] || [ -z "$HOLD_ASK" ] || pass+=(--ask "$HOLD_ASK")
  FM_CAPTAIN_HOLD_EXPECT_REASON=$reason "$0" hold "$id" --reason "$HOLD_REASON_REST" "${keep[@]}" "${pass[@]}"
}

command_defer() {
  local id=${1:-} until='' decision_file='' show decoded hold_kind hold_until reason
  local earliest stamp marker latest tmp kind_flag='' stamp_epoch
  local -a choice_flags=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --until) shift; until=${1:-} ;;
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  case "$until" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) fail "--until must be a YYYY-MM-DD date: $until" ;;
  esac
  [ -n "$decision_file" ] || fail "--decision-file is required; a deferral records the captain's words"
  load_decision "$decision_file"
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  stamp_epoch=$(fm_utc_iso_to_epoch "$stamp") || fail "cannot read the current time: $stamp"
  earliest=$(epoch_to_utc_iso $((stamp_epoch - 86400)))
  earliest=${earliest%%T*}
  marker="Captain deferral: until $until | decision digest: $DECISION_DIGEST"

  # Decide under the task lock whether this deferral is new, already applied,
  # or superseded by a newer one; only a new one checks its date.
  acquire_task_control_lock "$id"
  require_tasks_axi
  task_show_or_fail "$id" "task $id is absent from this home's configured backlog (data directory $DATA)"
  [ "$(show_field "$show" state)" != "done" ] || fail "task $id is already closed"
  hold_kind=$(show_field_value "$show" hold_kind)
  hold_until=$(show_field_value "$show" hold_until)
  [ "$hold_kind" = captain ] || fail "task $id is not held for the captain"
  decoded=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  latest=$(printf '%s\n' "$decoded" | grep '^Captain deferral: until ' | tail -1)
  case "$decoded" in
    *"$marker"*)
      # Recorded before: a no-op when it is applied or a newer deferral has
      # replaced it, so a replayed older answer never rolls the date back.
      if [ "$latest" != "$marker" ] || [ "$hold_until" = "$until" ]; then
        printf 'deferred: %s until %s\n' "$id" "$until"
        return 0
      fi
      ;;
    *)
      [[ ! "$until" < "$earliest" ]] \
        || fail "the deferral date $until has already passed (earliest accepted: $earliest)"
      ;;
  esac
  reason=$(fm_hold_reason_decode "$(show_field_value "$show" hold_reason)")
  if parse_hold_kind_prefix "$reason"; then
    kind_flag=$HOLD_DECISION_KIND
    reason=$HOLD_REASON_REST
    # The call keeps its choices; a dropped default stays its recommendation.
    [ -z "$HOLD_OPTIONS" ] || choice_flags+=(--options "$HOLD_OPTIONS" --recommend "$HOLD_RECOMMENDED")
    [ -z "$HOLD_ASK" ] || choice_flags+=(--ask "$HOLD_ASK")
  fi
  [ -n "$reason" ] || reason="captain decision pending"
  release_task_control_lock

  # Re-hold first, through the owner that takes its own lock, and record the
  # captain's words only once the hold stands, so a call closed in between is
  # never left carrying a deferral it did not get.
  if [ -n "$kind_flag" ]; then
    "$0" hold "$id" --reason "$reason" --kind "$kind_flag" --until "$until" ${choice_flags[@]+"${choice_flags[@]}"} >/dev/null \
      || fail "could not re-hold $id until $until"
  else
    "$0" hold "$id" --reason "$reason" --until "$until" >/dev/null \
      || fail "could not re-hold $id until $until"
  fi
  acquire_task_control_lock "$id"
  task_show_or_fail "$id" "task $id disappeared while deferring it"
  [ "$(show_field "$show" state)" != "done" ] || fail "task $id was closed while it was being deferred"
  decoded=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  case "$decoded" in
    *"$marker"*) : ;;
    *)
      tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-defer.XXXXXX") \
        || fail "cannot stage the deferral for $id"
      if ! printf '%s\n\nCaptain deferred: %s\n%s\n%s\n' "$decoded" "$stamp" "$marker" "$DECISION_TEXT" > "$tmp"; then
        rm -f -- "$tmp"
        fail "cannot stage the deferral for $id"
      fi
      if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
        rm -f -- "$tmp"
        fail "could not record the deferral on $id"
      fi
      rm -f -- "$tmp"
      ;;
  esac
  printf 'deferred: %s until %s\n' "$id" "$until"
}

# Every open row this home holds for the captain, one id per line. The listing's
# first field is the slug id and its last is the requested hold_kind, so a
# quoted title holding commas cannot shift either.
held_captain_task_ids() {
  local listing
  listing=$(tasks_axi list --state held --fields hold_kind --limit 100000 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($NF == "captain") print id
    }
  '
}

# The default a held row would release to now, or a non-zero return when it has
# none due. Reads the row in THIS shell (TASK_SHOW_OUTPUT is carried back).
hold_default_due() {  # <task-id> <now-epoch>; sets HOLD_DEFAULT_OPTION/HOLD_RELEASES_AT
  local id=$1 now=$2 show releases_epoch
  task_show "$id" || return 1
  show=$TASK_SHOW_OUTPUT
  [ "$(show_field "$show" state)" != "done" ] || return 1
  [ "$(show_field_value "$show" hold_kind)" = captain ] || return 1
  [ "$(show_field_value "$show" held)" = yes ] || return 1
  parse_hold_kind_prefix "$(fm_hold_reason_decode "$(show_field_value "$show" hold_reason)")" || return 1
  [ "$HOLD_DECISION_KIND" = reversible ] && [ -n "$HOLD_DEFAULT_OPTION" ] || return 1
  releases_epoch=$(fm_utc_iso_to_epoch "$HOLD_RELEASES_AT") || return 1
  [ "$now" -ge "$releases_epoch" ]
}

# Release one row to its default as the decision of record. Runs in a subshell
# of command_release_due so a refusal stops only this row; the control lock is
# released by the subshell's own EXIT trap.
release_hold_by_default() {  # <task-id> <now-epoch>
  local id=$1 now=$2 show body option task_kind release=1 occurrence
  trap captain_hold_cleanup EXIT
  acquire_task_control_lock "$id"
  # Re-read under the lock: an answer recorded since the scan wins.
  hold_default_due "$id" "$now" || return 0
  option=$HOLD_DEFAULT_OPTION
  show=$TASK_SHOW_OUTPUT
  body=$(show_field "$show" body)
  task_kind=$(show_field_value "$show" kind)
  [ "$task_kind" != captain ] || release=0
  DECISION_TEXT=$(printf 'Released by default: no captain answer within 72 hours of the default being recorded, due %s (standing rule of 2026-09-24; fork decision 2026-10-14).\nOption applied: %s' \
    "$HOLD_RELEASES_AT" "$option")
  DECISION_DIGEST=$(sha256_text "$DECISION_TEXT")
  occurrence=$(( $(resolution_record_count "$body") + 1 ))
  write_resolution_record "$id" defaulted "$body"
  close_answered "$id" "$release" || fail "could not close default-released captain-held task $id"
  remove_interrupted_answer_stamp "$id"
  publish_parent_resolution_then_retire "$id" "$occurrence" "released by default: $option"
  printf 'released by default: %s %s\n' "$id" "$option"
}

command_release_due() {
  local now ids id status=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  now=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  now=$(fm_utc_iso_to_epoch "$now") || fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp"
  require_tasks_axi
  ids=$(held_captain_task_ids) || fail "could not list the rows held for the captain"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    hold_default_due "$id" "$now" || continue
    ( release_hold_by_default "$id" "$now" ) || {
      printf 'fm-captain-hold: %s stays held; its default release failed\n' "$id" >&2
      status=1
    }
  done <<EOF
$ids
EOF
  return "$status"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The stored binding value, or empty when the source is unbound. An unreadable
# or wrong-schema record is a hard error rather than a silent "unbound":
# feeding nothing is the safe direction only when it is a deliberate choice,
# never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  if [ "$origin" != "$BINDING_ANY" ]; then
    case "$origin" in
      ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
    esac
  fi
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  if [ -z "$origin" ] || [ "$origin" = --any-origin ]; then
    origin=$BINDING_ANY
  else
    validate_slug legacy-origin "$origin"
  fi
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <task-id> <answer> <label> [<picked-choice>]
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
  [ -z "${5:-}" ] || printf 'Choice picked: %s\n' "$5"
}

# The recorded choice an answer picks, matched by label ignoring case and
# surrounding space, or nothing when the reason records no such choice.
picked_choice() {  # <decoded-reason> <answer>
  local wanted label
  local -a labels=()
  parse_hold_kind_prefix "$1" || return 0
  [ -n "$HOLD_OPTIONS" ] || return 0
  wanted=$(lowercase "$(trim_text "$2")")
  IFS='|' read -r -a labels <<< "$HOLD_OPTIONS"
  for label in "${labels[@]}"; do
    if [ "$(lowercase "$label")" = "$wanted" ]; then
      printf '%s' "$label"
      return 0
    fi
  done
}

legacy_keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

sanitize_reconcile_provenance() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1024
}

command_answers() {
  local origin='' source='' row rest key answer label mode id show state hold_kind body digest legacy_digest legacy_key
  local recorded_digest recorded_mode occurrence tmp err closed=0 skipped=0 reason release_flag tab=$'\t'
  local resolve_rc defer_until deferred=0 picked replay_digest recorded_pick
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      --any-origin) origin=$BINDING_ANY ;;
      --*) usage >&2; exit 2 ;;
      *)
        [ -z "$origin" ] || { usage >&2; exit 2; }
        origin=$1
        ;;
    esac
    shift
  done
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    validate_slug legacy-origin "$origin"
  fi
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS= read -r row; do
    key=${row%%"$tab"*}
    rest=''
    case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; esac
    answer=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    label=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) mode=${rest#*"$tab"} ;; *) mode='' ;; esac
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    if [ "$answer" = "$RECONCILE_VALUE" ]; then
      printf 'refused: %s (reconcile requests require a bound captured source)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    release_flag=''
    defer_until=''
    case "${mode:-}" in
      ''|done) : ;;
      release) release_flag=--release ;;
      until=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) defer_until=${mode#until=} ;;
      *)
        printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$mode")"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    if [ "$answer" = later ] && [ -z "$defer_until" ]; then
      printf 'refused: %s (a later answer defers the call and needs a date; record it with defer --until)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    resolve_rc=0
    id=$(resolve_entry "$origin" "$key" 2>"$err") || resolve_rc=$?
    id=${id%% *}
    if [ "$resolve_rc" = 2 ]; then
      reason=$(tr -d '\n' < "$err")
      printf 'skipped: %s (migrated-hold scan refused%s)\n' "$key" "${reason:+: $reason}"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$resolve_rc" -ne 0 ]; then
      # resolve_entry runs in a command substitution, so task_show's exit
      # cannot stop this loop; only its status crosses back. 124 means the
      # backend never answered, which is not the same as an unknown key and
      # must not be spent as a skip.
      [ "$resolve_rc" -ne 124 ] \
        || fail "the backlog backend exceeded its read bound resolving $key"
      printf 'skipped: %s (no captain-held task with that id)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    task_show "$id" || { printf 'skipped: %s (absent)\n' "$id"; skipped=$((skipped + 1)); continue; }
    show=$TASK_SHOW_OUTPUT
    # An answer, or the label shown with it (a board option's value is a slug
    # and its label the choice), that names a recorded choice ignoring case is
    # recorded verbatim plus the choice it picked. A closed call keeps its
    # reason; a released one does not, so its replay is matched against the
    # pick its newest resolution recorded.
    reason=$(fm_hold_reason_decode "$(show_field_value "$show" hold_reason)")
    picked=$(picked_choice "$reason" "$answer")
    [ -n "$picked" ] || [ -z "$label" ] || picked=$(picked_choice "$reason" "$label")
    keyed_decision_text "$source" "$id" "$answer" "$label" "$picked" > "$tmp" \
      || fail "cannot stage the captain decision for $id"
    digest=$(sha256_text "$(cat "$tmp")")
    replay_digest=$digest
    if [ -z "$picked" ]; then
      recorded_pick=$(decode_shown_value "$(show_field "$show" body)" 2>/dev/null \
        | sed -n 's/^Choice picked: //p' | head -1)
      [ -z "$recorded_pick" ] \
        || replay_digest=$(sha256_text "$(keyed_decision_text "$source" "$id" "$answer" "$label" "$recorded_pick")")
    fi
    legacy_digest=''
    if [ "$id" != "$key" ]; then
      legacy_key=$key
    elif { [ -z "$origin" ] || [ "$origin" = "$BINDING_ANY" ]; } \
      && [ "${id#*-decision-}" != "$id" ]; then
      legacy_key=${id#*-decision-}
    else
      legacy_key=''
    fi
    if [ -n "$legacy_key" ]; then
      legacy_digest=$(sha256_text "$(legacy_keyed_decision_text "$source" "$legacy_key" "$answer" "$label")")
    fi
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    body=$(show_field "$show" body)
    if [ -n "$defer_until" ]; then
      if [ "$state" = "done" ]; then
        printf 'skipped: %s (already closed)\n' "$id"
        skipped=$((skipped + 1))
      elif "$0" defer "$id" --until "$defer_until" --decision-file "$tmp" </dev/null >/dev/null 2>"$err"; then
        printf 'deferred: %s until %s\n' "$id" "$defer_until"
        deferred=$((deferred + 1))
      else
        reason=$(tr -d '\n' < "$err" | sed 's/^fm-captain-hold: //')
        printf 'skipped: %s (%s)\n' "$id" "$reason"
        skipped=$((skipped + 1))
      fi
      continue
    fi
    recorded_digest=$(recorded_decision_digest "$body" || true)
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    if body_has_resolution_record "$body" \
      && { [ "$recorded_digest" = "$digest" ] || [ "$recorded_digest" = "$replay_digest" ] \
        || { case "$body" in *"Resolution recorded by fm-decision-hold."*) true ;; *) false ;; esac \
          && [ -n "$legacy_digest" ] && [ "$recorded_digest" = "$legacy_digest" ]; }; }; then
      if { [ -z "$release_flag" ] && [ "$state" = "done" ] \
          && closed_answer_replay_mode_compatible "$recorded_mode" "$body"; } \
        || { [ "$release_flag" = --release ] && [ "$state" != "done" ] \
          && [ "$hold_kind" != captain ] && [ "$recorded_mode" = released ]; }; then
        occurrence=$(resolution_record_count "$body")
        case "$recorded_mode" in
          repaired) publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)" ;;
          released) publish_parent_resolution_then_retire "$id" "$occurrence" released ;;
          *) publish_parent_resolution_then_retire "$id" "$occurrence" answered ;;
        esac
        printf 'closed: %s\n' "$id"
        closed=$((closed + 1))
        continue
      fi
    fi
    if [ "$state" = "done" ]; then
      printf 'skipped: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$hold_kind" != captain ]; then
      printf 'skipped: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    # shellcheck disable=SC2086  # release_flag is empty or a single literal flag.
    if "$0" answer "$id" --decision-file "$tmp" $release_flag </dev/null >/dev/null 2>"$err"; then
      # A parent-channel delivery problem is reported on stderr by the answer
      # path even when the close succeeded; keep it visible.
      [ ! -s "$err" ] || cat "$err" >&2
      printf 'closed: %s\n' "$id"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-captain-hold: //')
      printf 'skipped: %s (%s)\n' "$id" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s deferred=%s skipped=%s\n' "$closed" "$deferred" "$skipped"
  [ "$skipped" -eq 0 ]
}

# --- reconcile: verify latest state, then close with evidence or annotate ----
#
# The semantics are owned by docs/captain-hold-lifecycle.md; this section owns
# the durable record and the two terminal operations that retire it. Nothing
# here closes a captain call on the strength of a reconcile alone: `close`
# demands the evidence that made the call moot, and `note` leaves it open.

RECONCILE_DIR="$STATE/reconcile-requests"
RECONCILE_SCHEMA=fm-reconcile-request.v1
RECONCILE_VALUE=reconcile

reconcile_request_path() { printf '%s/%s.request\n' "$RECONCILE_DIR" "$1"; }

# Idempotent per task: a repeated reconcile keeps the one request and its
# original timestamp, so a re-delivered board answer never resets the clock on
# an obligation that is already open.
reconcile_request_record() {  # <task-id> <provenance>
  local id=$1 source=$2 path tmp
  path=$(reconcile_request_path "$id")
  [ ! -e "$path" ] || return 0
  (umask 077; mkdir -p "$RECONCILE_DIR") || return 1
  [ -d "$RECONCILE_DIR" ] && [ ! -L "$RECONCILE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RECONCILE_DIR/.request.XXXXXX") || return 1
  if {
    printf 'schema=%s\n' "$RECONCILE_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'requested=%s\n' "${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf 'source=%s\n' "$(sanitize_reconcile_provenance "$source")"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

reconcile_request_read() {  # <task-id>; sets RECONCILE_REQUESTED/RECONCILE_SOURCE
  local id=$1 path schema task
  path=$(reconcile_request_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$RECONCILE_SCHEMA" ] || fail "reconcile request has an incompatible schema: $path"
  task=$(sed -n 's/^task=//p' "$path" | head -1)
  [ "$task" = "$id" ] || fail "reconcile request names a different task: $path"
  RECONCILE_REQUESTED=$(sed -n 's/^requested=//p' "$path" | head -1)
  RECONCILE_SOURCE=$(sed -n 's/^source=//p' "$path" | head -1)
}

reconcile_request_retire() {  # <task-id>
  rm -f -- "$(reconcile_request_path "$1")" \
    || fail "could not retire the pending reconcile request for $1"
}

publish_parent_resolution_then_retire() {  # <task-id> <occurrence> <note>
  local id=$1 occurrence=$2 note=$3 request
  request=$(reconcile_request_path "$id")
  publish_parent_hold "$id" "$occurrence" resolved "$note"
  if [ -e "$request" ] && [ "$PARENT_HOLD_PUBLISHED" != 1 ]; then
    fail "could not publish the answered captain-held task $id to its parent"
  fi
  reconcile_request_retire "$id"
}

command_reconcile_requests() {
  local source_id='' source='' origin row id note provenance show show_status=0 created=0 skipped=0 tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) shift; source_id=${1:-} ;;
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_source_id "$source_id"
  [ -n "$source" ] || fail "--source provenance is required"
  origin=$(read_binding "$source_id") || fail "cannot verify the binding for source $source_id"
  [ -n "$origin" ] || fail "source $source_id is not bound; no reconcile requests were created"
  require_tasks_axi
  while IFS= read -r row; do
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*) printf 'refused: %s (invalid task id)\n' "$id"; skipped=$((skipped + 1)); continue ;;
    esac
    [ "${#id}" -le 128 ] \
      || { printf 'refused: %s (task id is too long)\n' "$id"; skipped=$((skipped + 1)); continue; }
    acquire_task_control_lock "$id"
    show_status=0
    show=''
    task_show "$id" || show_status=$?
    [ "$show_status" -ne 0 ] || show=$TASK_SHOW_OUTPUT
    if [ "$show_status" -eq 124 ]; then
      fail "the backlog backend exceeded its read bound reading $id"
    fi
    if [ -z "$show" ]; then
      printf 'refused: %s (absent)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field "$show" state)" = "done" ]; then
      printf 'refused: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field_value "$show" hold_kind)" != captain ]; then
      printf 'refused: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
    else
      provenance=$source
      [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
      if reconcile_request_record "$id" "$provenance"; then
        printf 'reconcile: %s\n' "$id"
        created=$((created + 1))
      else
        printf 'refused: %s (cannot record the reconcile request)\n' "$id"
        skipped=$((skipped + 1))
      fi
    fi
    release_task_control_lock || fail "cannot release task control for $id"
  done
  printf 'reconcile-requests: created=%s skipped=%s\n' "$created" "$skipped"
  [ "$skipped" -eq 0 ]
}

command_reconcile() {
  local action=${1:-}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$action" in
    list)    reconcile_list "$@" ;;
    close)   reconcile_close "$@" ;;
    note)    reconcile_note "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

reconcile_list() {
  local path id count=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$RECONCILE_DIR" ] || { printf 'reconcile-requests: 0\n'; return 0; }
  for path in "$RECONCILE_DIR"/*.request; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.request}
    RECONCILE_REQUESTED=''
    RECONCILE_SOURCE=''
    reconcile_request_read "$id" || continue
    printf '%s\trequested=%s\tsource=%s\n' "$id" "$RECONCILE_REQUESTED" "$RECONCILE_SOURCE"
    count=$((count + 1))
  done
  printf 'reconcile-requests: %s\n' "$count"
}

# The moot outcome. The evidence is what closes the call, and the `reconciled`
# resolution mode is what keeps the record from claiming the captain answered.
reconcile_close() {
  local id=${1:-} evidence_file='' show state hold_kind body occurrence recorded_mode
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$evidence_file" ] || fail "--evidence-file is required; a moot call closes on evidence, never on assertion"
  load_decision "$evidence_file"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  occurrence=$(( $(resolution_record_count "$body") + 1 ))
  if [ "$state" = "done" ]; then
    # An exact retry finishes an interrupted close and stays idempotent; a
    # different evidence text on an already closed call is refused.
    body_has_resolution_record "$body" \
      || fail "task $id is already closed with no resolution record; use answer to record what closed it"
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different resolution; it cannot be reconciled again"
    [ "$(recorded_resolution_mode "$body" || true)" = reconciled ] \
      || fail "task $id was not closed by reconciliation"
    occurrence=$(resolution_record_count "$body")
    remove_interrupted_answer_stamp "$id"
    publish_parent_hold "$id" "$occurrence" resolved reconciled
    [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
      || fail "could not publish the reconciled captain-held task $id to its parent"
    reconcile_request_retire "$id"
    printf 'reconciled: %s\n' "$id"
    return 0
  fi
  [ "$hold_kind" = captain ] \
    || fail "task $id is not held for the captain; there is no captain call to reconcile"
  if body_has_resolution_record "$body" \
    && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$recorded_mode" = reconciled ] \
      || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a reconciliation retry"
    occurrence=$(resolution_record_count "$body")
  else
    write_resolution_record "$id" reconciled "$body"
  fi
  close_answered "$id" 0 || fail "could not close reconciled captain-held task $id"
  remove_interrupted_answer_stamp "$id"
  task_show_or_fail "$id" "task $id disappeared after closing"
  body_has_resolution_record "$(show_field "$show" body)" \
    || fail "captain-held task $id did not retain its durable resolution record"
  publish_parent_hold "$id" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
    || fail "could not publish the reconciled captain-held task $id to its parent"
  reconcile_request_retire "$id"
  printf 'reconciled: %s\n' "$id"
}

# The still-active outcome. The hold survives, so the call stays the captain's
# and stays on Captain's Call, now carrying what the re-check found.
reconcile_note() {
  local id=${1:-} note_file='' note show body stamp tmp note_digest marker
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-file) shift; note_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$note_file" ] || fail "--note-file is required; leaving a call open records what the re-check found"
  [ -f "$note_file" ] || fail "note file does not exist: $note_file"
  note=$(cat "$note_file")
  [ -n "$note" ] || fail "note file must not be empty"
  [ "$(printf '%s' "$note" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "note file exceeds 8192 bytes"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  command_open "$id" \
    || fail "task $id is not an open captain call; a note cannot keep a closed call open"
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  note_digest=$(sha256_text "$note")
  marker="Reconcile request: $RECONCILE_REQUESTED | $RECONCILE_SOURCE | note digest: $note_digest"
  case "$body" in
    *"$marker"*)
      reconcile_request_retire "$id" \
        || fail "could not retire the applied reconcile request for $id"
      command_open "$id" || fail "recording the reconcile note released captain-held task $id"
      printf 'still-open: %s\n' "$id"
      return 0
      ;;
  esac
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-note.XXXXXX") \
    || fail "cannot stage the reconcile note"
  if ! printf '%s\n\nCaptain hold reconciled: %s\n%s\n%s\n' "$body" "$stamp" "$marker" "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the reconcile note for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the reconcile note on $id"
  fi
  rm -f -- "$tmp"
  reconcile_request_retire "$id" \
    || fail "could not retire the applied reconcile request for $id"
  command_open "$id" || fail "recording the reconcile note released captain-held task $id"
  printf 'still-open: %s\n' "$id"
}

# Record where a board that carries an origin's captain calls can now be
# reached, on every still-open call of the origin's attested inventory, when a
# finished worker's board is handed over to firstmate; a link already recorded
# on a call is not written again.
command_board_link() {
  local origin=${1:-} url=${2:-} meta keys entry resolved id rc show body stamp tmp line
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  validate_one_line url "$url"
  case "$url" in
    http://*|https://*) ;;
    *) fail "board link must be an http or https URL: $url" ;;
  esac
  [ "${#url}" -le 512 ] || fail "board link exceeds 512 characters"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  [ "$(meta_value "$meta" decisions_reviewed)" = 1 ] \
    || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_value "$meta" decision_keys)
  require_tasks_axi
  line="Captain hold board: $url"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    resolved=$(resolve_entry "$origin" "$entry") || fail "cannot resolve inventory entry $entry of $origin"
    id=${resolved%% *}
    rc=0
    ( command_open "$id" ) || rc=$?
    case "$rc" in
      0) ;;
      1) printf 'skipped: %s (not an open captain call)\n' "$id"; continue ;;
      *) fail "cannot tell whether $id is an open captain call" ;;
    esac
    acquire_task_control_lock "$id"
    task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
    body=$(decode_shown_value "$(show_field "$show" body)") \
      || fail "could not decode the existing body for $id"
    case $'\n'"$body"$'\n' in
      *$'\n'"$line"$'\n'*)
        release_task_control_lock
        printf 'linked: %s %s\n' "$id" "$url"
        continue
        ;;
    esac
    stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
    tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-board.XXXXXX") \
      || fail "cannot stage the board link"
    if ! printf '%s\n\n%s\nBoard handed over from %s at %s.\n' "$body" "$line" "$origin" "$stamp" > "$tmp" \
      || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
      rm -f -- "$tmp"
      fail "could not record the board link on $id"
    fi
    rm -f -- "$tmp"
    release_task_control_lock
    printf 'linked: %s %s\n' "$id" "$url"
  done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' entry key status_file open has_meta=0 transfer_rc transfers=() resolved
  local resolved_how attested_by_prefix='' origin_state unrecorded_origin=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    CAPTAIN_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with task ids"
      validate_slug task-id "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      resolved=$(verify_entry_durable "$origin" "$entry") || exit $?
      origin_state=${resolved##* }
      resolved=${resolved% *}
      resolved_how=${resolved##* }
      resolved=${resolved%% *}
      if [ "$origin_state" = unrecorded ]; then
        unrecorded_origin="${unrecorded_origin}${unrecorded_origin:+ }$resolved"
      fi
      if [ "$resolved_how" = migrated-prefix ]; then
        attested_by_prefix="${attested_by_prefix}${attested_by_prefix:+ }$entry=$resolved"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  open=$(status_open_decisions "$status_file")
  if [ -n "$open" ] && [ -z "$keys" ]; then
    fail "origin $origin still has open captain decisions in its status stream; hold a captain task for what remains, or answer them, before attesting --none"
  fi

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      # A rewrite rather than an append keeps any pr= identity block last
      # (fm_pr_meta_rewrite); the staged copy is private like the record.
      CAPTAIN_META_TMP="$STATE/.$origin.meta.attest.${BASHPID:-$$}"
      if ! (umask 077 && fm_pr_meta_rewrite "$meta" "decisions_reviewed decision_keys" \
          decisions_reviewed=1 "decision_keys=$keys" > "$CAPTAIN_META_TMP") ||
        ! fm_backlog_atomic_transition publish "$CAPTAIN_META_TMP" "$meta" "task record" "$STATE"; then
        fail "could not record the decision attestation in $meta"
      fi
      CAPTAIN_META_TMP=
    fi
    fm_lock_release "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=0

    # Transfer every still-open status decision to the durable captain-held
    # inventory so the live status fold does not duplicate the same Captain's
    # Call item. The transfer lines are this home's own bookkeeping closes,
    # written by the turn that just reviewed the inventory, so they go through
    # ONE guarded self-announced append (bin/fm-wake-lib.sh) and do not wake
    # this same session; an append failure still fails this command loudly.
    if [ -n "$keys" ]; then
      while IFS=$'\t' read -r key _verb _summary; do
        [ -n "$key" ] || continue
        transfers+=("captain-held [key=$key]: tracked by $keys")
      done <<EOF
$open
EOF
      if [ "${#transfers[@]}" -gt 0 ]; then
        transfer_rc=0
        fm_wake_status_append_self_announced "$STATE" "$status_file" "${transfers[@]}" || transfer_rc=$?
        [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin"
      fi
    fi
  fi
  printf 'complete: %s captain-call inventory reviewed%s%s%s\n' "$origin" "${keys:+ ($keys)}" \
    "${attested_by_prefix:+ [attested through the configured prefix: $attested_by_prefix]}" \
    "${unrecorded_origin:+ [no recorded origin on: $unrecorded_origin; not checked against $origin]}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open resolved
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_entry_durable "$origin" "$entry" >/dev/null
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(status_open_decisions "$STATE/$origin.status")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    fail "open captain decision $origin/$key is not transferred to the captain-held inventory; re-run complete"
  done <<EOF
$open
EOF
  printf 'verified: %s captain-call inventory\n' "$origin"
}

# --- record divergence ------------------------------------------------------
#
# A captain call can be written down twice, and until now nothing said when
# those two records disagreed. A `resolved [key=...]` line closes the status-log
# fold outright; the structured captain-held task is closed by a SEPARATE act
# (`answer` above). Closing only on the status side therefore looks complete
# there while the durable record still says the captain owes an answer and
# keeps resurfacing it. The defect was never the separation; it was the silence.
#
# `diverged` is a read-only report of that contradiction and nothing else. It
# closes NOTHING. A captain call closed wrongly disappears without review, which
# is strictly worse than the noise this prints, so reconciling a divergence stays
# a human-owned act - and it runs in either direction: record what the captain
# actually said with `answer`, or re-open the status decision when that
# resolution was not the captain's word.
#
# What it flags, and only this: a task that is still open and still carries the
# captain-hold annotations, whose key was closed on the status side by the
# RESOLVE verb. The other closing verb is not a divergence: a `captain-held`
# close is the VERIFIED transfer to that very task, written by command_complete
# only after verifying it, so the structured row staying open behind it is the
# correct state. Neither is a still-open status decision - the OPEN DECISIONS
# fold already owns that one.
#
# Routed work is deliberately irrelevant. When the decision IS the deliverable
# there is nothing to route, so the test is only whether the status side already
# declared this task's key resolved.
# Nor does the report interpret why that resolution exists. A call can turn out
# not to be a captain arbitration at all - a premise can dissolve, or a question
# of fact can prove its first reading wrong - so the report says only that the
# two records disagree and names both reconciliation directions above.
#
# Cost stays flat on a healthy home: one `tasks-axi list`, one key scan per
# status log, and the precise per-key fold only for a key that already names a
# still-open task. If tasks-axi is unavailable or its listing cannot be parsed,
# the guard cannot read the structured record and prints nothing.
#
# Output: one `<task-id>\t<origin>\t<key>\t<title>` line per divergence, in
# status-log then key order; nothing when the two records agree.

# Every still-open task id in this home's backlog, one per line. Only the first
# two comma-separated listing fields are read - both are slugs that precede any
# quoted title - so a title containing commas or quotes cannot shift them.
open_task_ids() {
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_row_list "$data" 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($2 != "done") print id
    }
  '
}

# Every key token stated anywhere in a status log. A cheap candidate scan: it
# over-includes tokens that are only prose, and status_key_closing_verb below is
# what actually decides what the stream says about a key.
status_log_key_tokens() {  # <status-file>
  grep -o '\[key=[A-Za-z0-9._-]*\]' "$1" 2>/dev/null |
    sed 's/^\[key=//; s/\]$//' | LC_ALL=C sort -u
}

list_has_line() {  # <newline-separated-list> <value>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

command_diverged() {
  local ids resolve f origin tokens id keys key show title
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # Both records must belong to the SAME home or the comparison is meaningless:
  # tasks-axi reads $FM_HOME's backlog, so a state dir pointed somewhere else
  # would report one home's status logs against another home's tasks. Every
  # production caller pairs the two; a mismatch stays silent rather than
  # inventing a cross-home divergence.
  [ "$STATE" = "$FM_HOME/state" ] || return 0
  # A read-only listing on a per-wake path, so it skips the mutation-oriented
  # compatibility floor and its extra probes: a listing this parser cannot read
  # simply yields no candidates and the report stays silent.
  command -v tasks-axi >/dev/null 2>&1 || return 0
  ids=$(open_task_ids) || return 0
  [ -n "$ids" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    origin=$(basename "$f"); origin=${origin%.status}
    tokens=$(status_log_key_tokens "$f")
    [ -n "$tokens" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # The keys that could name this task in THIS log: the collapsed identity
      # (the key IS the task id) and, for a pre-collapse row, the legacy derived
      # one this origin would have minted.
      keys=$id
      case "$id" in
        "$origin-decision-"?*) keys="$keys"$'\n'"${id#"$origin-decision-"}" ;;
      esac
      while IFS= read -r key; do
        list_has_line "$tokens" "$key" || continue
        [ "$(status_key_closing_verb "$f" "$key")" = "$resolve" ] || continue
        task_show "$id" || continue
        show=$TASK_SHOW_OUTPUT
        [ "$(show_field "$show" state)" != "done" ] || continue
        [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
        # The title is the only free-text field here, and the report is
        # TAB-separated, so it goes through the same sanitizer every other
        # emitted field uses rather than being trusted to stay one clean line.
        title=$(sanitize_field "$(show_field_value "$show" title)")
        printf '%s\t%s\t%s\t%s\n' "$id" "$origin" "$key" "$title"
        break
      done <<INNER
$keys
INNER
    done <<EOF
$ids
EOF
  done
}

# Still an open captain call? Exit 0 yes, 1 no, 2 cannot tell (see the header).
# A row this home does not carry is 3 when the caller requests the distinction,
# and so is a home with no backlog file at all, because a backlog that does not
# exist holds nothing. Every read failure over a record that DOES exist is a 2,
# printed to stderr, because a mechanical closer must never read "cannot tell"
# as permission to close.
command_open() {  # <task-id> [--identity] [--distinguish-absent]
  local id='' identity=0 distinguish_absent=0 data state root file backend show shown_body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=1 ;;
      --distinguish-absent) distinguish_absent=1 ;;
      -*) usage >&2; exit 2 ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 2; }
        id=$1
        ;;
    esac
    shift
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'fm-captain-hold: task id must be a non-empty privacy-safe slug: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  data=$(fm_backlog_data_absolute "$DATA") \
    || { printf 'fm-captain-hold: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }
  root=$(fm_backlog_root "$data") \
    || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
  if ! backend=$(fm_tasks_axi_backend_resolve "$root"); then
    exit 2
  fi
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") \
      || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      # No backlog file at all: this home records no captain calls, so the task
      # is absent from it rather than held. A record that EXISTS but cannot be
      # read is a different state and still leaves by the exit 2 paths below,
      # because that one may hide a live hold.
      [ "$distinguish_absent" = 0 ] || return 3
      return 1
    fi
  fi
  fm_tasks_axi_compatible || { printf 'fm-captain-hold: compatible tasks-axi is required\n' >&2; exit 2; }
  if fm_backlog_row_probe "$data" "$id"; then
    state=${FM_BACKLOG_ROW_STATE%% *}
    if [ "$state" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      if [ "$identity" -eq 1 ]; then
        task_show "$id" || {
          printf 'fm-captain-hold: captain call %s is open but its record could not be read\n' "$id" >&2
          exit 2
        }
        show=$TASK_SHOW_OUTPUT
        shown_body=$(show_field "$show" body)
        printf '%s#%s\n' \
          "$(body_hold_set_timestamp "$(decode_shown_value "$shown_body")")" \
          "$(resolution_record_count "$shown_body")"
      fi
      return 0
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ "$distinguish_absent" = 0 ] || return 3
    return 1
  fi
  printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_ROW_ERROR" >&2
  exit 2
}

case "${1:-}" in
  hold) shift; command_hold "$@" ;;
  choices) shift; command_choices "$@" ;;
  release-due) shift; command_release_due "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  defer) shift; command_defer "$@" ;;
  reconcile-requests) shift; command_reconcile_requests "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  complete) shift; command_complete "$@" ;;
  board-link) shift; command_board_link "$@" ;;
  verify) shift; command_verify "$@" ;;
  open) shift; command_open "$@" ;;
  diverged) shift; command_diverged "$@" ;;
  reconcile) shift; command_reconcile "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

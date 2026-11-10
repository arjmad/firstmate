#!/usr/bin/env bash
# fm-data-media-prune.sh - the retention prune for torn-down tasks' data/<task>/
# directories, in three parts:
#   - media: remove the bulky video, audio, and disk images a task left once it
#     has been torn down and quiet for N days, keeping its reports and finals;
#   - scratch: once a task has been torn down and quiet for N days, apply
#     teardown's reproducible-scratch rule to it again
#     (bin/fm-data-scratch-prune.sh --keep-binaries), so clean pushed nested
#     checkouts and dependency folders a task kept from before that rule, or
#     from before its checkout was pushed, go too;
#   - size: when data/ as a whole is over a size trigger, name the largest
#     torn-down tasks and what each holds, so firstmate can propose a cleanup.
#
# Usage: fm-data-media-prune.sh [--dry-run] [--days <N>] [--scratch-days <N>]
#        --dry-run
#          Classify exactly as a real run would, change nothing (not even the
#          retention clocks below), and print one
#          `would remove: <KiB> data/<task>/<path>` line per media file and
#          bin/fm-data-scratch-prune.sh's own `would remove` and `kept` lines
#          per scratch item, then the summary lines.
#        --days <N>
#          Media retention in whole days, 1 to 3650. Overrides the config.
#        --scratch-days <N>
#          Scratch retention in whole days, 1 to 3650. Overrides the config.
#
# Media and scratch retention are each opt-in per home, separately, so a home
# that opted in to one never starts the other. config/data-media-retention-days
# holds the media N and config/data-scratch-retention-days the scratch N; with
# a part's file absent and no option for it, a real run skips that part, while
# --dry-run previews it with the default of 7 days. bin/fm-bootstrap.sh runs
# this real (not dry) as one of its locked MUTATING sweeps, so the caller must
# already hold this home's session lock; by hand, only --dry-run is safe while
# another live session holds it.
#
# The size trigger is on in every home. config/data-size-trigger-mib holds a
# whole number of MiB from 1 to 16777216 (default 4096, which is 4 GiB); data/
# is measured with one du per run, and the backlog is read only when a part
# needs it.
#
# Output. A run that removed (or under --dry-run would remove) any media prints
#   BOOTSTRAP_INFO: data media retention: removed <n> files (<MiB> MiB) from <m> torn-down tasks quiet over <N> days
# and any scratch
#   BOOTSTRAP_INFO: data scratch retention: removed <n> items (<MiB> MiB) from <m> torn-down tasks quiet over <N> days
# (`would remove` under --dry-run), and nothing otherwise; --dry-run also prints
#   data media retention: would start the retention clock for <k> torn-down tasks
# when it would. When data/ is over the size trigger, it prints
#   BOOTSTRAP_INFO: data size: data/ holds <X>, over the <T> trigger; ...
# naming where each kind of content goes, then one line for each of the five
# largest torn-down tasks, largest first:
#   BOOTSTRAP_INFO: data size: <task> <MiB> MiB: <a> MiB clean checkouts, <b> MiB dependency folders, <c> MiB images, <d> MiB PDFs, <e> MiB other
# where clean checkouts and dependency folders are what scratch retention would
# remove from it today, images and PDFs are what only a captain-approved Drive
# batch moves (docs/configuration.md), and other is the rest, kept checkouts
# included. A problem is a `warning:` on stderr. An unusable option or config
# value exits 2, except the size trigger's, which warns and uses the default;
# every other outcome exits 0 so a session start continues, and a backlog that
# cannot be read removes nothing.
#
# What counts as a task. Every directory directly under data/ that holds a
# brief.md (bin/fm-brief.sh writes it at dispatch) and is not a symlink. Other
# entries under data/ - the backlog, captain files, archives, boards - are
# never examined.
#
# When a task is torn down. None of its live records exists under state/
# (<task>.meta, <task>.status, <task>.inbox, <task>.turn-ended,
# <task>.backlog-close), and this home's backlog, read once per run through
# tasks-axi, holds no open row (any state but done) with its id. Teardown
# removes those records only after its landed-work gates pass and a refused
# teardown keeps the meta, so unlanded work and live or relaunched tasks keep
# their files; the backlog check keeps a briefed-but-unspawned task and a task
# whose captain call is still open (teardown retains its row) as well. When the
# backlog cannot be read - a manual backend, an absent markdown backlog, or a
# failing tasks-axi - the run warns and removes nothing.
#
# The retention clock. Teardown leaves no timestamp, so the first real run that
# finds a task torn down writes state/data-media-retention/<task>.retired and
# removes nothing from it that run; the clock is that file's modification time.
# A task whose records or open row come back loses its clock file, as does a
# task whose data directory is gone.
#
# When a task is quiet. For media, its clock file is older than N days and no
# regular file under data/<task>/ was modified within the last N days. For
# scratch, which teardown already applies with no clock, only the files count:
# none was modified within the last scratch N days. A failed scan counts as not
# quiet.
#
# What is removed. Only regular files (never symlinks or directories) under a
# torn-down, quiet task whose extension, in any case, is one of
#   video: mp4 mov m4v webm mkv avi
#   audio: mp3 wav m4a aac flac ogg opus
#   disk:  iso img raw qcow2 vmdk vdi dmg
# Still images, PDFs, and exports are never removed here: the captain's
# 2026-10-21 ruling moves those to Drive before anything is deleted
# (docs/fork-decisions/2026-10-26-task-media-retention.md).
# and that is not a final. The task's own .md, .json, .txt, .html, and .htm
# files are always kept, and a media file is a final when, ignoring case,
#   - its name contains "final", or
#   - its base name appears in one of those text files whose own name contains
#     "final" (a finals manifest such as finals.json), or
#   - its base name appears in a "final" passage of any of those text files:
#     a Markdown heading that says "final" opens a passage that runs to the
#     next heading, and any other line that says "final" opens one that runs
#     to the next blank line or heading, so a "## Final renders" section and a
#     pretty-printed "finals" array are covered whole.
# A board page or report that merely embeds a render does not make it a final,
# so review renders and clip copies go while the page that showed them stays.
# Directories left empty are kept too.
# Nothing inside a git checkout is touched: a directory under data/<task>/ that
# holds a .git entry, and everything below it, is skipped whole, because its
# files may be work that has not landed anywhere.
#
# What scratch retention removes. Exactly what
# `bin/fm-data-scratch-prune.sh --keep-binaries` removes from a torn-down,
# quiet task, whose header owns that rule: a nested checkout only when it is
# clean, holds no stash, and every commit it has is on a remote-tracking
# branch, and node_modules, .venv, and dist folders. Images, PDFs, reports,
# binaries, and every other file stay. A real run reports only what it
# removed; teardown and --dry-run name each kept checkout and why. As at
# teardown, a secondmate's data/<id>/ is never touched: an id
# data/secondmates.md names, or a folder holding a children/ directory of
# retired children's records, is skipped.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

DRY_RUN=0
DAYS=
SCRATCH_DAYS=
DEFAULT_DRY_RUN_DAYS=7
MAX_DAYS=3650
DEFAULT_SIZE_MIB=4096
MAX_SIZE_MIB=16777216
SIZE_TASKS=5
CLOCKS="$STATE/data-media-retention"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --days|--scratch-days)
      [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }
      if [ "$1" = --days ]; then DAYS=$2; else SCRATCH_DAYS=$2; fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# config_value <file>: print the file's value with whitespace removed, nothing
# when it is absent, and exit 2 when it is present but empty.
config_value() {
  local v
  [ -f "$1" ] || return 0
  v=$(tr -d '[:space:]' < "$1")
  [ -n "$v" ] || { echo "error: $1 is empty" >&2; exit 2; }
  printf '%s' "$v"
}

# whole_number <value> <max> <what>: print <value> without leading zeros, or
# exit 2 naming <what>. Digits only and no more of them after leading zeros
# than <max> has, so the arithmetic below can neither overflow nor read it as
# octal.
whole_number() {
  local v
  case "$1" in
    ''|*[!0-9]*) echo "error: $3 must be a whole number from 1 to $2, got '$1'" >&2; exit 2 ;;
  esac
  v=$(printf '%s' "$1" | sed 's/^0*//')
  if [ -z "$v" ] || [ "${#v}" -gt "${#2}" ] || [ "$v" -gt "$2" ]; then
    echo "error: $3 must be a whole number from 1 to $2" >&2
    exit 2
  fi
  printf '%s' "$v"
}

# retention_days <option value> <config file>: the part's N, or nothing when a
# real run skips that part (header).
retention_days() {
  local v=$1
  [ -n "$v" ] || v=$(config_value "$2") || exit 2
  if [ -z "$v" ]; then
    [ "$DRY_RUN" -eq 1 ] || return 0
    v=$DEFAULT_DRY_RUN_DAYS
  fi
  whole_number "$v" "$MAX_DAYS" "retention days" || exit 2
}

DAYS=$(retention_days "$DAYS" "$CONFIG/data-media-retention-days") || exit 2
SCRATCH_DAYS=$(retention_days "$SCRATCH_DAYS" "$CONFIG/data-scratch-retention-days") || exit 2
# The size trigger only reports, so an unusable value falls back to the
# default with a warning rather than stopping the retention a home opted in to.
SIZE_MIB=$(config_value "$CONFIG/data-size-trigger-mib" 2>/dev/null) || SIZE_MIB=bad
SIZE_MIB=$(whole_number "${SIZE_MIB:-$DEFAULT_SIZE_MIB}" "$MAX_SIZE_MIB" "the data size trigger in MiB" 2>/dev/null) || {
  echo "warning: $CONFIG/data-size-trigger-mib is not a whole number of MiB from 1 to $MAX_SIZE_MIB; using $DEFAULT_SIZE_MIB" >&2
  SIZE_MIB=$DEFAULT_SIZE_MIB
}
QUIET_MINUTES=$((${DAYS:-0} * 1440))
SCRATCH_QUIET_MINUTES=$((${SCRATCH_DAYS:-0} * 1440))

[ -d "$DATA" ] || exit 0

# measure_data: data/'s size and each top-level entry's, in KiB, from one du,
# and whether data/ is over the size trigger.
DATA_REAL=$(cd "$DATA" && pwd -P) || exit 0
measure_data() {
  DU_OUT=$(du -k -d 1 "$DATA_REAL" 2>/dev/null)
  DATA_KIB=$(printf '%s\n' "$DU_OUT" | awk -F '\t' -v d="$DATA_REAL" '$2 == d { print $1 }')
  case "$DATA_KIB" in ''|*[!0-9]*) DATA_KIB=0 ;; esac
  OVER_SIZE=0
  [ "$DATA_KIB" -le $((SIZE_MIB * 1024)) ] || OVER_SIZE=1
}
measure_data
[ -n "$DAYS" ] || [ -n "$SCRATCH_DAYS" ] || [ "$OVER_SIZE" -eq 1 ] || exit 0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-data-media-prune.XXXXXX") || { echo "warning: data media retention skipped: cannot create a scratch directory" >&2; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# human_kib <KiB>: a size in GiB to one decimal from 1 GiB up, else in MiB.
human_kib() {
  awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GiB", k / 1048576; else printf "%d MiB", k / 1024 }'
}

# size_line <tail>: the size trigger's first line, when data/ is over it.
size_line() {
  [ "$OVER_SIZE" -eq 1 ] || return 0
  printf 'BOOTSTRAP_INFO: data size: data/ holds %s, over the %s trigger; %s\n' \
    "$(human_kib "$DATA_KIB")" "$(human_kib $((SIZE_MIB * 1024)))" "$1"
}

# Open backlog ids, one per line. A backlog that cannot be read - a manual
# backend, an absent markdown file, or a failing tasks-axi - stops the run.
backlog_skip() {  # <why>
  echo "warning: data media retention skipped: the backlog could not be read ($1)" >&2
  size_line "torn-down tasks are unknown because the backlog could not be read"
  exit 0
}
! fm_backlog_backend_manual "$CONFIG" || backlog_skip "config/backlog-backend is manual"
fm_backlog_tasks_axi_addressing "$DATA" || backlog_skip "${FM_BACKLOG_TRANSITION_ERROR:-no backlog backend}"
[ -z "$FM_BACKLOG_AXI_FILE" ] || [ -f "$FM_BACKLOG_AXI_FILE" ] || backlog_skip "$FM_BACKLOG_AXI_FILE is missing"
backlog_out=$(FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30} fm_backlog_row_list "$DATA" --limit 1000000 2>&1)
backlog_status=$?
if [ "$backlog_status" -ne 0 ] || ! printf '%s\n' "$backlog_out" | grep -q '^count: [0-9]'; then
  backlog_skip "$(printf '%s\n' "$backlog_out" | sed -n '1p')"
fi
printf '%s\n' "$backlog_out" | sed -n 's/^  \([A-Za-z0-9._-]*\),\([a-z_]*\),.*/\1 \2/p' \
  | awk '$2 != "done" { print $1 }' | sort -u > "$WORK/open-ids"
# Newline-framed lists, so a membership test is a case match rather than a fork.
NL='
'
OPEN_IDS="$NL$(cat "$WORK/open-ids")$NL"

task_is_live() {  # <task>
  local suffix
  for suffix in meta status inbox turn-ended backlog-close; do
    if [ -e "$STATE/$1.$suffix" ] || [ -L "$STATE/$1.$suffix" ]; then
      return 0
    fi
  done
  case "$OPEN_IDS" in *"$NL$1$NL"*) return 0 ;; esac
  return 1
}

# True only when every regular file under <dir> is older than <minutes>; a
# scan that fails is not proof of quiet.
files_quiet() {  # <dir> <minutes>
  local recent
  recent=$(find "$1" -type f -mmin "-$2" -print 2>/dev/null) || return 1
  [ -z "$recent" ]
}

# True only when the clock file and every regular file under <dir> are older
# than the media retention.
task_is_quiet() {  # <dir> <clock>
  [ -z "$(find "$2" -mmin "-$QUIET_MINUTES" -print 2>/dev/null)" ] || return 1
  files_quiet "$1" "$QUIET_MINUTES"
}

# find arguments that skip every git checkout under the task (header); the
# caller's filter drops anything a path pattern could not express.
prune_args() {
  local root first=1
  PRUNE_ARGS=()
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ "$first" -eq 1 ]; then PRUNE_ARGS=('(' -path "$root"); first=0; else PRUNE_ARGS+=(-o -path "$root"); fi
  done < "$WORK/git-roots"
  [ "$first" -eq 1 ] || PRUNE_ARGS+=(')' -prune -o)
}

# Media candidates under <dir>, one path per line. A name holding a newline
# splits into lines naming no regular file, which the caller skips.
media_candidates() {  # <dir>
  find "$1" "${PRUNE_ARGS[@]+"${PRUNE_ARGS[@]}"}" -type f \( \
    -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.avi' -o \
    -iname '*.mp3' -o -iname '*.wav' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.opus' -o \
    -iname '*.iso' -o -iname '*.img' -o -iname '*.raw' -o -iname '*.qcow2' -o -iname '*.vmdk' -o -iname '*.vdi' -o -iname '*.dmg' \
    \) ! -iname '*final*' -print 2>/dev/null
}

# media_task <dir>: remove (or list) one torn-down, quiet task's media.
media_task() {
  local dir=$1 kib file task_files
  # Every git checkout under the task, as a path prefix ending in /.
  find "$dir" -name .git -prune -print 2>/dev/null | sed 's|/\.git$||' > "$WORK/git-roots"
  prune_args
  media_candidates "$dir" > "$WORK/all"
  if [ -s "$WORK/git-roots" ]; then
    awk 'FILENAME == ARGV[1] { roots[++n] = $0 "/"; next }
      { for (i = 1; i <= n; i++) if (index($0, roots[i]) == 1) next; print }' \
      "$WORK/git-roots" "$WORK/all" > "$WORK/candidates"
  else
    mv "$WORK/all" "$WORK/candidates"
  fi
  [ -s "$WORK/candidates" ] || return 0
  # Lowercased base names a finals manifest or a "final" passage names (header).
  awk '{ n = $0; sub(/.*\//, "", n); print tolower(n) }' "$WORK/candidates" | sort -u > "$WORK/names"
  find "$dir" "${PRUNE_ARGS[@]+"${PRUNE_ARGS[@]}"}" -type f \
    \( -iname '*.md' -o -iname '*.json' -o -iname '*.txt' -o -iname '*.html' -o -iname '*.htm' \) \
    -exec awk 'FNR == 1 { n = FILENAME; sub(/.*\//, "", n); whole = (tolower(n) ~ /final/); on = 0; heading = 0 }
      { line = tolower($0) }
      whole { print line; next }
      line ~ /^#/ { on = (line ~ /final/); heading = on; if (on) print line; next }
      line ~ /^[[:space:]]*$/ { if (!heading) on = 0; next }
      line ~ /final/ { on = 1 }
      on { print line }' {} + 2>/dev/null | grep -F -o -f "$WORK/names" | sort -u > "$WORK/referenced"
  awk 'FILENAME == ARGV[1] { keep[$0] = 1; next }
    { n = $0; sub(/.*\//, "", n); if (!(tolower(n) in keep)) print }' \
    "$WORK/referenced" "$WORK/candidates" > "$WORK/remove"
  [ -s "$WORK/remove" ] || return 0
  # One du for the task's sizes; a path du cannot read (a split name) drops out.
  tr '\n' '\0' < "$WORK/remove" | xargs -0 du -k 2>/dev/null > "$WORK/sizes"
  task_files=0
  while IFS="$(printf '\t')" read -r kib file; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "$kib" in ''|*[!0-9]*) kib=0 ;; esac
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would remove: %s data/%s\n' "$kib" "${file#"$DATA"/}"
    elif ! rm -f -- "$file"; then
      echo "warning: could not remove $file" >&2
      continue
    fi
    task_files=$((task_files + 1))
    TOTAL_KIB=$((TOTAL_KIB + kib))
  done < "$WORK/sizes"
  if [ "$task_files" -gt 0 ]; then
    TOTAL_FILES=$((TOTAL_FILES + task_files))
    TOTAL_TASKS=$((TOTAL_TASKS + 1))
  fi
}

# scratch_items <scratch-prune output>: print "<items> <KiB>" for its removed
# (or would-remove) item lines, the per-task summary line excluded.
scratch_items() {
  printf '%s\n' "$1" | awk '
    /^data-scratch: (removed|would remove) (checkout|node_modules|venv|dist|binary) / {
      if (match($0, /\([0-9]+ KiB\)$/)) kib += substr($0, RSTART + 1, RLENGTH - 6)
      n++
    }
    END { printf "%d %d\n", n, kib }'
}

# scratch_task <dir>: apply the scratch rule to one torn-down, quiet task.
scratch_task() {
  local out items kib
  if [ "$DRY_RUN" -eq 1 ]; then
    out=$("$SCRIPT_DIR/fm-data-scratch-prune.sh" --dry-run --keep-binaries "$1" </dev/null)
    [ -z "$out" ] || printf '%s\n' "$out"
  else
    out=$("$SCRIPT_DIR/fm-data-scratch-prune.sh" --keep-binaries "$1" </dev/null)
  fi
  read -r items kib <<EOF
$(scratch_items "$out")
EOF
  [ "$items" -gt 0 ] || return 0
  SCRATCH_ITEMS=$((SCRATCH_ITEMS + items))
  SCRATCH_KIB=$((SCRATCH_KIB + kib))
  SCRATCH_TASK_COUNT=$((SCRATCH_TASK_COUNT + 1))
}

# kib_of_files <list-file>: the summed KiB of the regular files it names.
kib_of_files() {
  [ -s "$1" ] || { echo 0; return; }
  tr '\n' '\0' < "$1" | xargs -0 du -k 2>/dev/null | awk -F '\t' '{ k += $1 } END { printf "%d\n", k }'
}

# size_task <dir> <KiB>: one size-trigger line naming what the task holds.
size_task() {
  local dir=$1 total=$2 out ck dep img pdf other
  out=$("$SCRIPT_DIR/fm-data-scratch-prune.sh" --dry-run --keep-binaries "$dir" </dev/null 2>/dev/null)
  ck=$(printf '%s\n' "$out" | awk '/^data-scratch: would remove checkout / && match($0, /\([0-9]+ KiB\)$/) {
    k += substr($0, RSTART + 1, RLENGTH - 6) } END { printf "%d\n", k }')
  dep=$(printf '%s\n' "$out" | awk '/^data-scratch: would remove (node_modules|venv|dist) / && match($0, /\([0-9]+ KiB\)$/) {
    k += substr($0, RSTART + 1, RLENGTH - 6) } END { printf "%d\n", k }')
  # Images and PDFs outside every checkout and every dependency folder scratch
  # retention would remove: the files only a captain-approved Drive batch moves.
  find "$dir" -name .git -prune -print 2>/dev/null | sed 's|/\.git$||' > "$WORK/git-roots"
  printf '%s\n' "$out" | sed -n 's|^data-scratch: would remove [a-z_]* \(.*\) ([0-9]* KiB)$|\1|p' \
    | while IFS= read -r rel; do printf '%s\n' "$DATA/$rel"; done >> "$WORK/git-roots"
  prune_args
  find "$dir" "${PRUNE_ARGS[@]+"${PRUNE_ARGS[@]}"}" -type d -name node_modules -prune \
    -o -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \
    -o -iname '*.svg' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.bmp' \
    -o -iname '*.avif' -o -iname '*.ico' -o -iname '*.pdf' \) -print 2>/dev/null \
    | awk 'FILENAME == ARGV[1] { roots[++n] = $0 "/"; next }
      { for (i = 1; i <= n; i++) if (index($0, roots[i]) == 1) next; print }' "$WORK/git-roots" - > "$WORK/visuals"
  grep -i '\.pdf$' "$WORK/visuals" > "$WORK/pdfs" || true
  grep -iv '\.pdf$' "$WORK/visuals" > "$WORK/images" || true
  img=$(kib_of_files "$WORK/images")
  pdf=$(kib_of_files "$WORK/pdfs")
  other=$((total - ck - dep - img - pdf))
  [ "$other" -ge 0 ] || other=0
  printf 'BOOTSTRAP_INFO: data size: %s %s MiB: %s MiB clean checkouts, %s MiB dependency folders, %s MiB images, %s MiB PDFs, %s MiB other\n' \
    "${dir##*/}" "$((total / 1024))" "$((ck / 1024))" "$((dep / 1024))" "$((img / 1024))" "$((pdf / 1024))" "$((other / 1024))"
}

TOTAL_FILES=0
TOTAL_KIB=0
TOTAL_TASKS=0
NEW_CLOCKS=0
SCRATCH_ITEMS=0
SCRATCH_KIB=0
SCRATCH_TASK_COUNT=0
: > "$WORK/retired"
if [ -n "$DAYS" ] && [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$CLOCKS" 2>/dev/null || { echo "warning: data media retention skipped: cannot create $CLOCKS" >&2; exit 0; }
fi

# One walk of data/ per part names the tasks holding any candidate at all, so
# the per-task scans below run only for those.
task_names() {  # stdin paths under data/ -> the task directory names, once each
  awk -v p="$DATA/" 'index($0, p) == 1 { r = substr($0, length(p) + 1); if (sub(/\/.*/, "", r)) print r }' | sort -u
}
PRUNE_ARGS=()
MEDIA_TASKS=$NL
[ -z "$DAYS" ] || MEDIA_TASKS="$NL$(media_candidates "$DATA" | task_names)$NL"
# Every id data/secondmates.md names, as whole words.
SECONDMATE_IDS="$NL$( [ ! -f "$DATA/secondmates.md" ] || grep -o '[A-Za-z0-9._-][A-Za-z0-9._-]*' "$DATA/secondmates.md" | sort -u)$NL"
SCRATCH_TASKS=$NL
[ -z "$SCRATCH_DAYS" ] || SCRATCH_TASKS="$NL$(find "$DATA" -mindepth 2 \( -name .git -o -type d \( -name node_modules -o -name .venv -o -name dist \) \) \
  -prune -print 2>/dev/null | task_names)$NL"

for dir in "$DATA"/*/; do
  dir=${dir%/}
  task=${dir##*/}
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/brief.md" ] || continue
  clock="$CLOCKS/$task.retired"
  if task_is_live "$task"; then
    [ -z "$DAYS" ] || [ "$DRY_RUN" -eq 1 ] || rm -f "$clock"
    continue
  fi
  printf '%s\n' "$task" >> "$WORK/retired"
  # Teardown never applies the scratch rule to a secondmate's data/<id>/, so
  # neither does retention: a registered secondmate, or a folder holding
  # retired children's records, is skipped.
  case "$SCRATCH_TASKS" in
    *"$NL$task$NL"*)
      if [ ! -e "$dir/children" ] && ! case "$SECONDMATE_IDS" in *"$NL$task$NL"*) true ;; *) false ;; esac \
        && files_quiet "$dir" "$SCRATCH_QUIET_MINUTES"; then
        scratch_task "$dir"
      fi
      ;;
  esac
  [ -n "$DAYS" ] || continue
  if [ ! -f "$clock" ]; then
    NEW_CLOCKS=$((NEW_CLOCKS + 1))
    [ "$DRY_RUN" -eq 1 ] || : > "$clock" || echo "warning: could not start the retention clock for $task" >&2
    continue
  fi
  case "$MEDIA_TASKS" in *"$NL$task$NL"*) ;; *) continue ;; esac
  task_is_quiet "$dir" "$clock" || continue
  media_task "$dir"
done

# A clock whose task directory is gone has nothing left to time.
if [ -n "$DAYS" ] && [ "$DRY_RUN" -eq 0 ]; then
  for clock in "$CLOCKS"/*.retired; do
    [ -f "$clock" ] || continue
    task=${clock##*/}
    task=${task%.retired}
    [ -d "$DATA/$task" ] || rm -f "$clock"
  done
fi

verb=removed
[ "$DRY_RUN" -eq 0 ] || verb="would remove"
if [ "$TOTAL_FILES" -gt 0 ]; then
  printf 'BOOTSTRAP_INFO: data media retention: %s %s files (%s MiB) from %s torn-down tasks quiet over %s days\n' \
    "$verb" "$TOTAL_FILES" "$((TOTAL_KIB / 1024))" "$TOTAL_TASKS" "$DAYS"
fi
if [ "$SCRATCH_ITEMS" -gt 0 ]; then
  printf 'BOOTSTRAP_INFO: data scratch retention: %s %s items (%s MiB) from %s torn-down tasks quiet over %s days\n' \
    "$verb" "$SCRATCH_ITEMS" "$((SCRATCH_KIB / 1024))" "$SCRATCH_TASK_COUNT" "$SCRATCH_DAYS"
fi
if [ "$DRY_RUN" -eq 1 ] && [ "$NEW_CLOCKS" -gt 0 ]; then
  printf 'data media retention: would start the retention clock for %s torn-down tasks\n' "$NEW_CLOCKS"
fi

# The size trigger, measured again when this run removed anything.
if [ "$DRY_RUN" -eq 0 ] && [ $((TOTAL_FILES + SCRATCH_ITEMS)) -gt 0 ]; then
  measure_data
fi
if [ "$OVER_SIZE" -eq 1 ]; then
  # Each torn-down task's KiB from the du above, largest first.
  printf '%s\n' "$DU_OUT" | awk -F '\t' -v p="$DATA_REAL/" 'FILENAME == ARGV[1] { retired[$0] = 1; next }
      index($2, p) == 1 { t = substr($2, length(p) + 1); if (t in retired) print $1 "\t" t }' "$WORK/retired" - \
    | sort -t "$(printf '\t')" -k1,1nr -k2 | head -n "$SIZE_TASKS" > "$WORK/largest"
  if [ -s "$WORK/largest" ]; then
    size_line "its largest torn-down tasks follow. Clean checkouts and dependency folders go with scratch retention (config/data-scratch-retention-days); images and PDFs move to Drive only as one captain-approved batch (docs/configuration.md)"
    while IFS="$(printf '\t')" read -r kib task; do
      size_task "$DATA/$task" "$kib"
    done < "$WORK/largest"
  else
    size_line "no torn-down task holds any of it"
  fi
fi
exit 0

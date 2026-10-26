#!/usr/bin/env bash
# fm-data-media-prune.sh - remove the bulky video, audio, and disk images a
# torn-down task left in its data/<task>/ directory once that task has been
# torn down and quiet for N days, keeping its reports and its finals.
#
# Usage: fm-data-media-prune.sh [--dry-run] [--days <N>]
#        --dry-run
#          Classify exactly as a real run would, change nothing (not even the
#          retention clocks below), and print one
#          `would remove: <KiB> data/<task>/<path>` line per file, then the
#          summary lines.
#        --days <N>
#          Retention in whole days, 1 to 3650. Overrides the config.
#
# Retention is opt-in per home. config/data-media-retention-days holds N; with
# that file absent and no --days, a real run does nothing and prints nothing,
# while --dry-run previews with the default of 7 days. bin/fm-bootstrap.sh runs
# this real (not dry) as one of its locked MUTATING sweeps, so the caller must
# already hold this home's session lock; by hand, only --dry-run is safe while a
# live session holds it.
#
# Output. A run that removed (or under --dry-run would remove) anything prints
#   BOOTSTRAP_INFO: data media retention: removed <n> files (<MiB> MiB) from <m> torn-down tasks quiet over <N> days
# (`would remove` under --dry-run), and nothing otherwise; --dry-run also prints
#   data media retention: would start the retention clock for <k> torn-down tasks
# when it would. A problem is a `warning:` on stderr. An unusable --days or
# config value exits 2; every other outcome exits 0 so a session start
# continues, and a backlog that cannot be read removes nothing.
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
# When a task is quiet. Its clock file is older than N days and no regular file
# under data/<task>/ was modified within the last N days. A failed scan counts
# as not quiet.
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
DEFAULT_DRY_RUN_DAYS=7
MAX_DAYS=3650
CLOCKS="$STATE/data-media-retention"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --days)
      [ $# -ge 2 ] || { echo "error: --days needs a value" >&2; exit 2; }
      DAYS=$2
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$DAYS" ] && [ -f "$CONFIG/data-media-retention-days" ]; then
  DAYS=$(tr -d '[:space:]' < "$CONFIG/data-media-retention-days")
  [ -n "$DAYS" ] || { echo "error: $CONFIG/data-media-retention-days is empty" >&2; exit 2; }
fi
if [ -z "$DAYS" ]; then
  [ "$DRY_RUN" -eq 1 ] || exit 0
  DAYS=$DEFAULT_DRY_RUN_DAYS
fi
# Digits only and at most four of them after leading zeros, so the arithmetic
# below can neither overflow nor read the value as octal.
case "$DAYS" in
  ''|*[!0-9]*) echo "error: retention days must be a whole number from 1 to $MAX_DAYS, got '$DAYS'" >&2; exit 2 ;;
esac
DAYS=$(printf '%s' "$DAYS" | sed 's/^0*//')
if [ -z "$DAYS" ] || [ "${#DAYS}" -gt 4 ] || [ "$DAYS" -gt "$MAX_DAYS" ]; then
  echo "error: retention days must be a whole number from 1 to $MAX_DAYS" >&2
  exit 2
fi
QUIET_MINUTES=$((DAYS * 1440))

[ -d "$DATA" ] || exit 0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-data-media-prune.XXXXXX") || { echo "warning: data media retention skipped: cannot create a scratch directory" >&2; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# Open backlog ids, one per line. A backlog that cannot be read - a manual
# backend, an absent markdown file, or a failing tasks-axi - stops the run.
backlog_skip() {  # <why>
  echo "warning: data media retention skipped: the backlog could not be read ($1)" >&2
  exit 0
}
! fm_backlog_backend_manual "$CONFIG" || backlog_skip "config/backlog-backend is manual"
fm_backlog_tasks_axi_addressing "$DATA" || backlog_skip "${FM_BACKLOG_TRANSITION_ERROR:-no backlog backend}"
[ -z "$FM_BACKLOG_AXI_FILE" ] || [ -f "$FM_BACKLOG_AXI_FILE" ] || backlog_skip "$FM_BACKLOG_AXI_FILE is missing"
backlog_out=$(FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30} fm_backlog_row_list "$DATA" --limit 1000000 2>&1)
backlog_status=$?
if [ "$backlog_status" -ne 0 ] || ! printf '%s\n' "$backlog_out" | grep -q '^count: [0-9]'; then
  echo "warning: data media retention skipped: the backlog could not be read ($(printf '%s\n' "$backlog_out" | sed -n '1p'))" >&2
  exit 0
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

# True only when the clock file and every regular file under <dir> are older
# than the retention; a scan that fails is not proof of quiet.
task_is_quiet() {  # <dir> <clock>
  local recent
  [ -z "$(find "$2" -mmin "-$QUIET_MINUTES" -print 2>/dev/null)" ] || return 1
  recent=$(find "$1" -type f -mmin "-$QUIET_MINUTES" -print 2>/dev/null) || return 1
  [ -z "$recent" ]
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

TOTAL_FILES=0
TOTAL_KIB=0
TOTAL_TASKS=0
NEW_CLOCKS=0
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$CLOCKS" 2>/dev/null || { echo "warning: data media retention skipped: cannot create $CLOCKS" >&2; exit 0; }

# One walk of data/ names the tasks holding any candidate at all, so the
# per-task scans below run only for those.
PRUNE_ARGS=()
media_candidates "$DATA" | awk -v p="$DATA/" 'index($0, p) == 1 {
    r = substr($0, length(p) + 1); if (sub(/\/.*/, "", r)) print r }' | sort -u > "$WORK/media-tasks"
MEDIA_TASKS="$NL$(cat "$WORK/media-tasks")$NL"

for dir in "$DATA"/*/; do
  dir=${dir%/}
  task=${dir##*/}
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/brief.md" ] || continue
  clock="$CLOCKS/$task.retired"
  if task_is_live "$task"; then
    [ "$DRY_RUN" -eq 1 ] || rm -f "$clock"
    continue
  fi
  if [ ! -f "$clock" ]; then
    NEW_CLOCKS=$((NEW_CLOCKS + 1))
    [ "$DRY_RUN" -eq 1 ] || : > "$clock" || echo "warning: could not start the retention clock for $task" >&2
    continue
  fi
  case "$MEDIA_TASKS" in *"$NL$task$NL"*) ;; *) continue ;; esac
  task_is_quiet "$dir" "$clock" || continue
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
  [ -s "$WORK/candidates" ] || continue
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
  [ -s "$WORK/remove" ] || continue
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
done

# A clock whose task directory is gone has nothing left to time.
if [ "$DRY_RUN" -eq 0 ]; then
  for clock in "$CLOCKS"/*.retired; do
    [ -f "$clock" ] || continue
    task=${clock##*/}
    task=${task%.retired}
    [ -d "$DATA/$task" ] || rm -f "$clock"
  done
fi

if [ "$TOTAL_FILES" -gt 0 ]; then
  verb=removed
  [ "$DRY_RUN" -eq 0 ] || verb="would remove"
  printf 'BOOTSTRAP_INFO: data media retention: %s %s files (%s MiB) from %s torn-down tasks quiet over %s days\n' \
    "$verb" "$TOTAL_FILES" "$((TOTAL_KIB / 1024))" "$TOTAL_TASKS" "$DAYS"
fi
if [ "$DRY_RUN" -eq 1 ] && [ "$NEW_CLOCKS" -gt 0 ]; then
  printf 'data media retention: would start the retention clock for %s torn-down tasks\n' "$NEW_CLOCKS"
fi
exit 0

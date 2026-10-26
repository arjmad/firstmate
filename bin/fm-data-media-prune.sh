#!/usr/bin/env bash
# fm-data-media-prune.sh - remove the bulky media a torn-down task left in its
# data/<task>/ directory once that task has been quiet for N days, keeping its
# reports and anything they reference.
#
# Usage: fm-data-media-prune.sh [--dry-run] [--days <N>]
#        --dry-run
#          Classify exactly as a real run would, remove nothing, and print one
#          `would remove: <KiB> data/<task>/<path>` line per file, then the
#          summary line.
#        --days <N>
#          Retention in whole days (a positive integer). Overrides the config.
#
# Retention is opt-in per home. config/data-media-retention-days holds N; with
# that file absent and no --days, a real run does nothing and prints nothing,
# while --dry-run previews with the default of 7 days. bin/fm-bootstrap.sh runs
# this real (not dry) as one of its locked MUTATING sweeps, so the caller must
# already hold this home's session lock; by hand, only --dry-run is safe while a
# live session holds it.
#
# Output. A run that removed (or under --dry-run would remove) anything ends
# with one line:
#   BOOTSTRAP_INFO: data media retention: removed <n> files (<MiB> MiB) from <m> torn-down tasks quiet over <N> days
# (`would remove` under --dry-run), and nothing otherwise. A problem is a
# `warning:` on stderr; an unusable --days or config value exits 2, and every
# other outcome exits 0 so a session start continues.
#
# What counts as a task. Every directory directly under data/ that holds a
# brief.md (bin/fm-brief.sh writes it at dispatch) and is not a symlink. Other
# entries under data/ - the backlog, captain files, archives, boards - are
# never examined.
#
# When a task is retired. None of its live records exists under state/:
# <task>.meta, <task>.status, <task>.inbox, <task>.turn-ended, or
# <task>.backlog-close. bin/fm-teardown.sh removes those only after its
# landed-work gates pass, and a refused teardown keeps the meta, so unlanded
# work and live or relaunched tasks always keep their files. A successor spawn
# that reuses the id recreates the meta and makes the task live again.
#
# When a task is quiet. No regular file anywhere under data/<task>/ was
# modified within the last N days.
#
# What is removed. Only regular files (never symlinks or directories) under a
# retired, quiet task whose extension, in any case, is one of
#   video: mp4 mov m4v webm mkv avi
#   audio: mp3 wav m4a aac flac ogg opus
#   image: png jpg jpeg gif webp heic tif tiff bmp
#   disk:  iso img raw qcow2 vmdk vdi dmg
# and that is not a final. The task's own .md, .json, .txt, .html, and .htm
# files are always kept, and a media file is a final when
#   - its name contains "final" in any case, or
#   - its base name appears in one of those text files whose own name contains
#     "final" (a finals manifest such as finals.json), or
#   - its base name appears on a line of any of those text files that also says
#     "final" in any case (a report's "final cut: build/x.mp4").
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

DRY_RUN=0
DAYS=
DEFAULT_DRY_RUN_DAYS=7

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
case "$DAYS" in
  ''|*[!0-9]*|0*) echo "error: retention days must be a positive integer, got '$DAYS'" >&2; exit 2 ;;
esac
QUIET_MINUTES=$((DAYS * 1440))

[ -d "$DATA" ] || exit 0

task_is_live() {  # <task>
  local suffix
  for suffix in meta status inbox turn-ended backlog-close; do
    if [ -e "$STATE/$1.$suffix" ] || [ -L "$STATE/$1.$suffix" ]; then
      return 0
    fi
  done
  return 1
}

task_is_quiet() {  # <dir>
  local recent
  recent=$(find "$1" -type f -mmin "-$QUIET_MINUTES" -print 2>/dev/null | head -n 1)
  [ -z "$recent" ]
}

# Media candidates under <dir>, one path per line. A name holding a newline
# splits into lines naming no regular file, which the caller skips.
media_candidates() {  # <dir>
  find "$1" -type f \( \
    -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.avi' -o \
    -iname '*.mp3' -o -iname '*.wav' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.opus' -o \
    -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.heic' -o \
    -iname '*.tif' -o -iname '*.tiff' -o -iname '*.bmp' -o \
    -iname '*.iso' -o -iname '*.img' -o -iname '*.raw' -o -iname '*.qcow2' -o -iname '*.vmdk' -o -iname '*.vdi' -o -iname '*.dmg' \
    \) ! -iname '*final*' -print 2>/dev/null
}

TOTAL_FILES=0
TOTAL_KIB=0
TOTAL_TASKS=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-data-media-prune.XXXXXX") || { echo "warning: cannot create a scratch directory" >&2; exit 0; }
trap 'rm -rf "$WORK"' EXIT

for dir in "$DATA"/*/; do
  dir=${dir%/}
  task=${dir##*/}
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/brief.md" ] || continue
  task_is_live "$task" && continue
  task_is_quiet "$dir" || continue
  media_candidates "$dir" > "$WORK/all"
  # Drop every candidate inside a git checkout (header).
  find "$dir" -name .git -print 2>/dev/null | sed 's|/\.git$|/|' > "$WORK/git-roots"
  if [ -s "$WORK/git-roots" ]; then
    awk 'NR == FNR { roots[++n] = $0; next }
      { for (i = 1; i <= n; i++) if (index($0, roots[i]) == 1) next; print }' \
      "$WORK/git-roots" "$WORK/all" > "$WORK/candidates"
  else
    mv "$WORK/all" "$WORK/candidates"
  fi
  [ -s "$WORK/candidates" ] || continue
  # Base names a finals manifest or a line saying "final" names stay (header).
  sed 's|.*/||' "$WORK/candidates" | sort -u > "$WORK/names"
  find "$dir" -type f \( -iname '*.md' -o -iname '*.json' -o -iname '*.txt' -o -iname '*.html' -o -iname '*.htm' \) \
    -print 2>/dev/null > "$WORK/texts"
  while IFS= read -r text; do
    case "$(printf '%s' "${text##*/}" | tr '[:upper:]' '[:lower:]')" in
      *final*) cat -- "$text" ;;
      *) grep -i -h -- final "$text" ;;
    esac 2>/dev/null
  done < "$WORK/texts" | grep -F -o -h -f "$WORK/names" | sort -u > "$WORK/referenced"
  task_files=0
  while IFS= read -r file; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    name=${file##*/}
    grep -F -x -q -- "$name" "$WORK/referenced" && continue
    kib=$(du -k "$file" 2>/dev/null | cut -f1)
    case "$kib" in ''|*[!0-9]*) kib=0 ;; esac
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would remove: %s data/%s\n' "$kib" "${file#"$DATA"/}"
    elif ! rm -f -- "$file"; then
      echo "warning: could not remove $file" >&2
      continue
    fi
    task_files=$((task_files + 1))
    TOTAL_KIB=$((TOTAL_KIB + kib))
  done < "$WORK/candidates"
  if [ "$task_files" -gt 0 ]; then
    TOTAL_FILES=$((TOTAL_FILES + task_files))
    TOTAL_TASKS=$((TOTAL_TASKS + 1))
  fi
done

if [ "$TOTAL_FILES" -gt 0 ]; then
  verb=removed
  [ "$DRY_RUN" -eq 0 ] || verb="would remove"
  printf 'BOOTSTRAP_INFO: data media retention: %s %s files (%s MiB) from %s torn-down tasks quiet over %s days\n' \
    "$verb" "$TOTAL_FILES" "$((TOTAL_KIB / 1024))" "$TOTAL_TASKS" "$DAYS"
fi
exit 0

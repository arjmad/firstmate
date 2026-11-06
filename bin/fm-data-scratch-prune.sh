#!/usr/bin/env bash
# fm-data-scratch-prune.sh - delete the reproducible scratch a task left in its
# data/<task>/ folder: nested git checkouts with nothing uncommitted or
# unpushed, node_modules folders, and downloaded tool binaries. Reports,
# briefs, notes, and every other file stay.
#
# Usage: fm-data-scratch-prune.sh [--dry-run] <task-data-dir>
#        --dry-run
#          Classify exactly as a real run would and change nothing; each
#          `removed` line below reads `would remove` instead.
#
# bin/fm-teardown.sh runs this real (not dry) on data/<id>/ under the task's
# meta lock, after its landed-work gates pass and just before its record is
# removed, so the rule applies at teardown with no clock and no batch.
# By hand it is safe on any task folder whose task is not running.
#
# Output, one line per item, paths relative to the parent of <task-data-dir>:
#   data-scratch: removed checkout|node_modules|binary <task>/<path> (<KiB> KiB)
#   data-scratch: kept checkout|node_modules <task>/<path>: <why>
# then, when anything was (or would be) removed,
#   data-scratch: removed <n> items (<MiB> MiB) from <task>/
# A problem is a `warning:` on stderr. A missing folder prints nothing; an
# unusable argument exits 2; every other outcome exits 0, so teardown never
# fails on it.
#
# What is a checkout. A directory below <task-data-dir> holding a .git
# directory. <task-data-dir> itself being a checkout makes the run do nothing.
# A .git file (a linked worktree or a submodule) is kept, since its history
# lives in another repository whose records would be left dangling.
#
# When a checkout is removed. All of these hold, checked innermost first:
#   - git resolves it as its own top level, so a broken .git never lets git
#     answer for an enclosing repository;
#   - it has no linked worktree, and no repository under <task-data-dir>
#     borrows its objects through objects/info/alternates;
#   - no checkout below it is kept;
#   - `git status --porcelain -z --untracked-files=all` succeeds and is empty,
#     except for a nested checkout this run removes;
#   - it holds no stash;
#   - HEAD, every local branch, and every tag are reachable from a
#     remote-tracking branch
#     (`git rev-list HEAD --branches --tags --not --remotes` succeeds and is
#     empty), so a checkout with no remote, no commit, or a history git cannot
#     read stays; a remote-tracking branch counts as pushed, as it does for
#     teardown's own landed-work check;
#   - no remote URL is a local path inside <task-data-dir>.
# Anything else keeps the checkout whole, with everything inside it, and says
# why: never delete a checkout with unlanded work. Every checkout is decided
# before any is deleted, and only the outermost removable ones are deleted.
# Ignored files go with a removed checkout, as they are not work git would land.
# Git runs without optional locks or fsmonitor, so reading a checkout changes
# nothing in it.
#
# What else is removed, outside every checkout:
#   - every directory named node_modules (not a symlink), whole, unless it
#     holds a kept checkout, which keeps it and is named;
#   - every regular file (not a symlink) whose header marks an ELF or Mach-O
#     executable or shared library: the downloaded tool binaries. Core dumps,
#     object files, and Java classes stay.
# Text, images, PDFs, archives, and exports are never removed here; the
# 60-day retention rule in docs/configuration.md owns those.
set -u

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
DIR=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; exit 2 ;;
    *)
      [ -z "$DIR" ] || { echo "error: one task data directory only" >&2; exit 2; }
      DIR=$1
      ;;
  esac
  shift
done
[ -n "$DIR" ] || { echo "error: usage: fm-data-scratch-prune.sh [--dry-run] <task-data-dir>" >&2; exit 2; }
[ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 0
DIR=$(cd "$DIR" && pwd -P) || exit 0
TASK=${DIR##*/}
[ ! -e "$DIR/.git" ] || exit 0

export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
export GIT_OPTIONAL_LOCKS=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-data-scratch-prune.XXXXXX") || { echo "warning: data scratch prune skipped: cannot create a scratch directory" >&2; exit 0; }
trap 'rm -rf "$WORK"' EXIT

VERB=removed
[ "$DRY_RUN" -eq 0 ] || VERB="would remove"
TOTAL_ITEMS=0
TOTAL_KIB=0

# remove <kind> <path>: size, delete (unless dry), and report one item.
remove() {
  local kib
  kib=$(du -sk "$2" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$kib" in ''|*[!0-9]*) kib=0 ;; esac
  if [ "$DRY_RUN" -eq 0 ] && ! rm -rf -- "$2"; then
    echo "warning: could not remove $2" >&2
    return 1
  fi
  printf 'data-scratch: %s %s %s/%s (%s KiB)\n' "$VERB" "$1" "$TASK" "${2#"$DIR"/}" "$kib"
  TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
  TOTAL_KIB=$((TOTAL_KIB + kib))
}

keep() {  # <path> <why>
  printf 'data-scratch: kept checkout %s/%s: %s\n' "$TASK" "${1#"$DIR"/}" "$2"
}

# under_dir: keep only stdin paths below <task-data-dir>, so a name holding a
# newline, which splits into lines, can never point outside it.
under_dir() {
  awk -v d="$DIR/" 'index($0, d) == 1'
}

# has_ancestor <path> <list>: true when <list> names a directory holding <path>.
has_ancestor() {
  awk -v p="$1" 'index(p, $0 "/") == 1 { found = 1 } END { exit !found }' "$2"
}

# has_descendant <path> <list>: true when <list> names a path inside <path>.
has_descendant() {
  awk -v p="$1/" 'index($0, p) == 1 { found = 1 } END { exit !found }' "$2"
}

# Every checkout root, deepest first, so an inner checkout is decided before
# the one holding it.
find "$DIR" -mindepth 2 -name .git -prune -print 2>/dev/null | sed 's|/\.git$||' | under_dir \
  | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2- > "$WORK/roots"
: > "$WORK/kept"
: > "$WORK/removable"
# Every alternates entry under the task, as a resolved directory followed by
# the file naming it, so a checkout another repository borrows from stays.
find "$DIR" -path '*/objects/info/alternates' -type f -print 2>/dev/null | under_dir > "$WORK/alternates-files"
: > "$WORK/alternates"
while IFS= read -r alt_file; do
  [ -f "$alt_file" ] || continue
  while IFS= read -r alt || [ -n "$alt" ]; do
    case "$alt" in ''|'#'*) continue ;; /*) ;; *) alt="${alt_file%/info/alternates}/$alt" ;; esac
    alt=$(cd "$alt" 2>/dev/null && pwd -P) || continue
    printf '%s\t%s\n' "$alt" "$alt_file" >> "$WORK/alternates"
  done < "$alt_file"
done < "$WORK/alternates-files"

# remote_in_task <root>: true when a remote URL is a local path inside the
# task folder, whose own copy this run may delete.
remote_in_task() {
  local url path
  git -C "$1" config --get-regexp '^remote\..*\.url$' 2>/dev/null | sed 's/^[^ ]* //' > "$WORK/urls"
  while IFS= read -r url; do
    case "$url" in
      file://*) path=${url#file://} ;;
      *://*) continue ;;
      /*) path=$url ;;
      *)
        case "${url%%/*}" in *:*) continue ;; esac
        path="$1/$url"
        ;;
    esac
    path=$(cd "$path" 2>/dev/null && pwd -P) || continue
    case "$path/" in "$DIR/"*) return 0 ;; esac
  done < "$WORK/urls"
  return 1
}

# checkout_verdict <root>: print why it must stay, or nothing when it may go.
checkout_verdict() {
  local root=$1 entry rel unpushed top
  [ -d "$root/.git" ] && [ ! -L "$root/.git" ] || { echo "a linked worktree or submodule"; return; }
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" 2>/dev/null && pwd -P) \
    && [ "$top" = "$root" ] || { echo "git does not read it as its own repository"; return; }
  if [ -n "$(find "$root/.git/worktrees" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ]; then
    echo "it has linked worktrees"
    return
  fi
  if awk -F '\t' -v r="$root/" 'index($1 "/", r) == 1 && index($2, r) != 1 { found = 1 } END { exit !found }' "$WORK/alternates"; then
    echo "another repository borrows its objects"
    return
  fi
  if has_descendant "$root" "$WORK/kept"; then
    echo "it holds a kept checkout"
    return
  fi
  git -C "$root" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all > "$WORK/status" 2>/dev/null \
    || { echo "git cannot read its status"; return; }
  while IFS= read -r -d '' entry; do
    case "$entry" in
      '?? '*/)
        rel=${entry#?? }
        grep -Fqx -- "$root/${rel%/}" "$WORK/removable" && continue
        ;;
    esac
    echo "uncommitted changes"
    return
  done < "$WORK/status"
  if git -C "$root" rev-parse -q --verify refs/stash >/dev/null 2>&1; then
    echo "a stash"
    return
  fi
  unpushed=$(git -C "$root" rev-list -n 1 HEAD --branches --tags --not --remotes 2>/dev/null) || { echo "git cannot read its commits"; return; }
  [ -z "$unpushed" ] || { echo "commits no remote-tracking branch holds"; return; }
  if remote_in_task "$root"; then
    echo "its remote is inside this task folder"
  fi
}

# Decide every checkout before deleting any, so a dry run decides the same way
# and a kept checkout keeps everything inside it.
while IFS= read -r root; do
  [ -n "$root" ] || continue
  why=$(checkout_verdict "$root")
  if [ -n "$why" ]; then
    keep "$root" "$why"
    printf '%s\n' "$root" >> "$WORK/kept"
  else
    printf '%s\n' "$root" >> "$WORK/removable"
  fi
done < "$WORK/roots"

# Only the outermost removable checkouts are deleted: an inner one goes with
# its removable holder, and one inside a kept checkout stays with it.
cp "$WORK/removable" "$WORK/removable-walk"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  if has_ancestor "$root" "$WORK/kept"; then
    keep "$root" "it is inside a kept checkout"
    continue
  fi
  has_ancestor "$root" "$WORK/removable" && continue
  remove checkout "$root" || true
done < "$WORK/removable-walk"

# inside_checkout: filter stdin paths, dropping any that is or is inside a
# checkout root (kept ones are untouchable; removed ones are already gone or,
# dry, counted).
inside_checkout() {
  awk 'FILENAME == ARGV[1] { roots[++n] = $0 "/"; next }
    { for (i = 1; i <= n; i++) if (index($0 "/", roots[i]) == 1) next; print }' "$WORK/roots" -
}

find "$DIR" -name .git -prune -o -type d -name node_modules -prune -print 2>/dev/null \
  | under_dir | inside_checkout > "$WORK/node-modules"
while IFS= read -r nm; do
  [ "${nm##*/}" = node_modules ] && [ -d "$nm" ] && [ ! -L "$nm" ] || continue
  if has_descendant "$nm" "$WORK/kept"; then
    printf 'data-scratch: kept node_modules %s/%s: it holds a kept checkout\n' "$TASK" "${nm#"$DIR"/}"
    continue
  fi
  remove node_modules "$nm" || true
done < "$WORK/node-modules"

# tool_binary <file>: true for an ELF or Mach-O executable or shared library.
# Core dumps, object files, and Java classes share those magic numbers and stay.
tool_binary() {
  local h type
  h=$(od -An -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n')
  [ "${#h}" -eq 40 ] || return 1
  case "${h:0:8}" in
    7f454c46)
      # e_type at byte 16, in the byte order EI_DATA (byte 5) names.
      case "${h:10:2}" in 01) type=${h:34:2}${h:32:2} ;; 02) type=${h:32:4} ;; *) return 1 ;; esac
      [ "$type" = 0002 ] || [ "$type" = 0003 ]
      ;;
    feedface|feedfacf)
      # filetype at byte 12, big-endian.
      type=${h:24:8}
      [ "$type" = 00000002 ] || [ "$type" = 00000006 ]
      ;;
    cefaedfe|cffaedfe)
      # filetype at byte 12, little-endian.
      type=${h:30:2}${h:28:2}${h:26:2}${h:24:2}
      [ "$type" = 00000002 ] || [ "$type" = 00000006 ]
      ;;
    cafebabe)
      # A universal binary's architecture count; a Java class has its version
      # (45 or more) there instead.
      type=$((16#${h:8:8}))
      [ "$type" -ge 1 ] && [ "$type" -lt 45 ]
      ;;
    *) return 1 ;;
  esac
}

find "$DIR" \( -name .git -o -type d -name node_modules \) -prune -o -type f -size +0 -print 2>/dev/null \
  | under_dir | inside_checkout > "$WORK/files"
while IFS= read -r file; do
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  tool_binary "$file" || continue
  remove binary "$file" || true
done < "$WORK/files"

if [ "$TOTAL_ITEMS" -gt 0 ]; then
  printf 'data-scratch: %s %s items (%s MiB) from %s/\n' "$VERB" "$TOTAL_ITEMS" "$((TOTAL_KIB / 1024))" "$TASK"
fi
exit 0

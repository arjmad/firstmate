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
# bin/fm-teardown.sh runs this real (not dry) on data/<id>/ once a task's
# record is gone, so the rule applies at teardown with no clock and no batch.
# By hand it is safe on any task folder whose task is not running.
#
# Output, one line per item, paths relative to the parent of <task-data-dir>:
#   data-scratch: removed checkout|node_modules|binary <task>/<path> (<KiB> KiB)
#   data-scratch: kept checkout <task>/<path>: <why>
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
#   - `git status --porcelain --untracked-files=all` succeeds and is empty,
#     except for a nested checkout this run removes;
#   - it holds no stash;
#   - HEAD and every local branch are reachable from a remote-tracking branch
#     (`git rev-list HEAD --branches --not --remotes` succeeds and is empty), so
#     a checkout with no remote, no commit, or a history git cannot read stays;
#   - git resolves it as its own top level, so a broken .git never lets git
#     answer for an enclosing repository;
#   - it has no linked worktree, and no repository under <task-data-dir>
#     borrows its objects through objects/info/alternates;
#   - no checkout below it is kept.
# Anything else keeps the checkout whole, with everything inside it, and says
# why: never delete a checkout with unlanded work. Ignored files go with a
# removed checkout, as they are not work git would land.
#
# What else is removed, outside every checkout:
#   - every directory named node_modules (not a symlink), whole;
#   - every regular file (not a symlink) whose first bytes are an ELF or Mach-O
#     header: the downloaded tool binaries.
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

# Every checkout root, deepest first, so an inner checkout is decided before
# the one holding it.
find "$DIR" -mindepth 2 -name .git -prune -print 2>/dev/null | sed 's|/\.git$||' \
  | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2- > "$WORK/roots"
: > "$WORK/kept"
: > "$WORK/removed"
# Every alternates entry under the task, as a resolved directory followed by
# the file naming it, so a checkout another repository borrows from stays.
find "$DIR" -path '*/objects/info/alternates' -type f -print 2>/dev/null > "$WORK/alternates-files"
: > "$WORK/alternates"
while IFS= read -r alt_file; do
  [ -f "$alt_file" ] || continue
  while IFS= read -r alt || [ -n "$alt" ]; do
    case "$alt" in ''|'#'*) continue ;; /*) ;; *) alt="${alt_file%/info/alternates}/$alt" ;; esac
    alt=$(cd "$alt" 2>/dev/null && pwd -P) || continue
    printf '%s\t%s\n' "$alt" "$alt_file" >> "$WORK/alternates"
  done < "$alt_file"
done < "$WORK/alternates-files"

# checkout_verdict <root>: print why it must stay, or nothing when it may go.
checkout_verdict() {
  local root=$1 status line rel unpushed top
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
  if awk -v r="$root/" 'index($0, r) == 1 { found = 1 } END { exit !found }' "$WORK/kept"; then
    echo "it holds a kept checkout"
    return
  fi
  status=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) || { echo "git cannot read its status"; return; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '?? '*/)
        rel=${line#?? }
        grep -Fqx -- "$root/${rel%/}" "$WORK/removed" && continue
        ;;
    esac
    echo "uncommitted changes"
    return
  done <<EOF
$status
EOF
  if git -C "$root" rev-parse -q --verify refs/stash >/dev/null 2>&1; then
    echo "a stash"
    return
  fi
  unpushed=$(git -C "$root" rev-list -n 1 HEAD --branches --not --remotes 2>/dev/null) || { echo "git cannot read its commits"; return; }
  [ -z "$unpushed" ] || echo "commits no remote-tracking branch holds"
}

while IFS= read -r root; do
  [ -n "$root" ] || continue
  why=$(checkout_verdict "$root")
  if [ -n "$why" ]; then
    keep "$root" "$why"
    printf '%s\n' "$root" >> "$WORK/kept"
  elif remove checkout "$root"; then
    printf '%s\n' "$root" >> "$WORK/removed"
  else
    printf '%s\n' "$root" >> "$WORK/kept"
  fi
done < "$WORK/roots"

# inside_checkout: filter stdin paths, dropping any inside a checkout root
# (kept ones are untouchable; removed ones are already gone or, dry, counted).
inside_checkout() {
  awk 'FILENAME == ARGV[1] { roots[++n] = $0 "/"; next }
    { for (i = 1; i <= n; i++) if (index($0, roots[i]) == 1) next; print }' "$WORK/roots" -
}

find "$DIR" -name .git -prune -o -type d -name node_modules -prune -print 2>/dev/null \
  | inside_checkout > "$WORK/node-modules"
while IFS= read -r nm; do
  [ -d "$nm" ] && [ ! -L "$nm" ] || continue
  remove node_modules "$nm" || true
done < "$WORK/node-modules"

find "$DIR" \( -name .git -o -type d -name node_modules \) -prune -o -type f -size +0 -print 2>/dev/null \
  | inside_checkout > "$WORK/files"
while IFS= read -r file; do
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  case "$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')" in
    7f454c46|feedface|feedfacf|cefaedfe|cffaedfe|cafebabe) remove binary "$file" || true ;;
  esac
done < "$WORK/files"

if [ "$TOTAL_ITEMS" -gt 0 ]; then
  printf 'data-scratch: %s %s items (%s MiB) from %s/\n' "$VERB" "$TOTAL_ITEMS" "$((TOTAL_KIB / 1024))" "$TASK"
fi
exit 0

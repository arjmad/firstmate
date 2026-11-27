#!/usr/bin/env bash
# fm-home-patch.sh - carry a ship's home-file half as one reviewed diff and
# apply it once the ship's PR lands (audit a1-61).
#
# Usage:
#   fm-home-patch.sh add <task-id> <home-path> <edited-copy>
#   fm-home-patch.sh show <task-id>
#   fm-home-patch.sh apply <task-id>
#   fm-home-patch.sh -h | --help
#
# A worker never edits its home's data/ or config/. When its change also needs
# one of those files changed, it writes the exact change to
# data/<task-id>/home-patch.md instead, and the landing step shows that diff
# and applies it, so the helm reviews one diff rather than re-deriving it.
#
# The file. Any Markdown prose, plus one or more fenced blocks whose opening
# fence is a column-0 run of three or more backticks or tildes followed by
# `diff`, closed by the same fence at column 0. Their contents, in order, are
# one unified diff whose paths are relative to the home, as `a/data/x` and
# `b/data/x`. A diff line never starts at column 0 with a fence, because every
# content line carries a leading space, `+` or `-`, so a fence inside the
# edited text cannot close the block early. An unclosed block is refused.
#
# add copies nothing and edits nothing in the home: it diffs the live
# <home-path> against <edited-copy>, a scratch copy the worker edited, appends
# that diff as one block (creating the file with a heading when absent), and
# then prints show's verdict. Run it once per file, against the live file, so
# each block's context is what the home holds now.
#
# What a patch may change. Only an existing regular file under the home's
# data/ or config/, reached through no symlink, and only its content: a path
# under state/, an absolute path, a `..` or `.` component, a quoted path, a
# binary hunk, and any create, delete, rename, copy or mode change are refused
# before anything is applied. data/captain.md and data/captain-shared.md are
# refused too, because only the captain's own word writes his rulings.
#
# show prints the patch's paths, its diff, and one verdict line:
#   home-patch: <id>: applies cleanly        (exit 0)
#   home-patch: <id>: already applied        (exit 3)
#   home-patch: <id>: none                   (exit 4; nothing else printed)
#   home-patch: <id>: refused: <why>         (exit 1)
#   home-patch: <id>: does not apply: <why>  (exit 1)
# apply runs the same checks. A patch that applies is applied whole through
# `git apply`, which changes no file unless every hunk applies, and
# data/<id>/home-patch.applied records the applied diff's sha256; it then
# prints `home-patch: <id>: applied to <paths>` and exits 0. An already applied
# patch, by that record or because the reverse diff applies, is a silent exit 3,
# so a re-run, a task's second PR and teardown after a merge-time apply are
# no-ops. A refused or drifted patch changes nothing, keeps the file, prints
# one `actionable:` line on stderr and exits 1. No patch is a silent exit 4.
# A usage error exits 2.
#
# The diff is applied with the home as the root whether or not the home is a
# git checkout: GIT_CEILING_DIRECTORIES stops git from finding a repository
# above the home, so a home nested in another checkout is still its own root.
#
# Who runs it. bin/fm-pr-merge.sh prints show's output as note: lines before
# the forge merge and runs apply after an attended merge is confirmed; under
# away or branch authority it leaves the patch pending, because nobody reviewed
# it. bin/fm-teardown.sh runs apply for a ship whose merge was recorded, when
# no away record exists and the main session is the actor, and files a noticed
# row for a patch it leaves unapplied. Neither caller's exit changes with it.
#
# Environment: FM_HOME selects the home (patch paths are relative to it);
# FM_DATA_OVERRIDE moves only where data/<task-id>/home-patch.md is read.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

CMD=${1:-}
case "$CMD" in
  add) [ "$#" -eq 4 ] || { usage >&2; exit 2; } ;;
  show|apply) [ "$#" -eq 2 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
ID=$2
case "$ID" in
  ''|*[!A-Za-z0-9._-]*|.*) echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac
HOME_ROOT=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd -P) || {
  echo "error: home $FM_HOME is not a readable directory" >&2
  exit 2
}
PATCH="$DATA/$ID/home-patch.md"
APPLIED="$DATA/$ID/home-patch.applied"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-home-patch.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
DIFF="$WORK/patch.diff"

# git apply with the home as its root (see the header).
home_git_apply() {
  (
    cd "$HOME_ROOT" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
    GIT_CEILING_DIRECTORIES=$(dirname "$HOME_ROOT") git apply "$@"
  )
}

# Why <rel> may not be patched, on stdout; nothing when it may.
path_refusal() {  # <rel>
  local rel=$1 dir
  case "$rel" in
    '"'*) echo "a quoted path is not accepted: $rel"; return ;;
    /*) echo "an absolute path is outside the home: $rel"; return ;;
    data/captain.md|data/captain-shared.md) echo "$rel holds the captain's own rulings"; return ;;
    data/?*|config/?*) ;;
    *) echo "$rel is not under data/ or config/"; return ;;
  esac
  case "/$rel/" in
    */../*|*/./*|*//*) echo "$rel has a . or .. component"; return ;;
  esac
  dir=$rel
  while [ "$dir" != "${dir%/*}" ]; do
    dir=${dir%/*}
    if [ -L "$HOME_ROOT/$dir" ]; then
      echo "$rel is reached through the symlink $dir"
      return
    fi
  done
  if [ -L "$HOME_ROOT/$rel" ] || [ ! -f "$HOME_ROOT/$rel" ]; then
    echo "$rel is not an existing regular file in the home"
  fi
}

# Writes the diff blocks of the patch file to $DIFF. Fails on an unclosed block.
extract_diff() {
  awk '
    fence == "" && /^(```+|~~~+)diff[ \t]*$/ {
      fence = $0; sub(/diff[ \t]*$/, "", fence); next
    }
    fence != "" {
      line = $0; sub(/[ \t]+$/, "", line)
      if (line == fence) { fence = ""; next }
      print; next
    }
    END { if (fence != "") exit 3 }
  ' "$PATCH" >"$DIFF"
}

PATHS=
VERDICT=
VERDICT_RC=
# Sets VERDICT, VERDICT_RC and PATHS for the patch file (see the header's codes).
judge() {
  local rc=0 numstat summary added deleted rel why sha recorded
  PATHS=
  if [ ! -e "$PATCH" ] && [ ! -L "$PATCH" ]; then
    VERDICT=none VERDICT_RC=4
    return
  fi
  if [ -L "$PATCH" ] || [ ! -f "$PATCH" ]; then
    VERDICT="refused: $PATCH is not a regular file" VERDICT_RC=1
    return
  fi
  extract_diff || rc=$?
  if [ "$rc" -ne 0 ]; then
    VERDICT="refused: a diff block in $PATCH is never closed" VERDICT_RC=1
    return
  fi
  if ! grep -q . "$DIFF"; then
    VERDICT="refused: $PATCH holds no \`\`\`diff block" VERDICT_RC=1
    return
  fi
  if ! numstat=$(home_git_apply --numstat "$DIFF" 2>&1); then
    VERDICT="refused: the diff does not parse: $(printf '%s' "$numstat" | head -n 1)" VERDICT_RC=1
    return
  fi
  summary=$(home_git_apply --summary "$DIFF" 2>&1) || summary="unreadable summary"
  if [ -n "$summary" ]; then
    VERDICT="refused: it creates, deletes, renames or changes a mode: $(printf '%s' "$summary" | head -n 1 | sed 's/^ *//')" VERDICT_RC=1
    return
  fi
  while IFS="$(printf '\t')" read -r added deleted rel; do
    [ -n "$rel" ] || continue
    if [ "$added" = - ] || [ "$deleted" = - ]; then
      VERDICT="refused: $rel is a binary hunk" VERDICT_RC=1
      return
    fi
    why=$(path_refusal "$rel")
    if [ -n "$why" ]; then
      VERDICT="refused: $why" VERDICT_RC=1
      return
    fi
    PATHS="${PATHS:+$PATHS, }$rel"
  done <<EOF
$numstat
EOF
  sha=$(git hash-object "$DIFF") || sha=
  recorded=$(sed -n 's/^sha=//p' "$APPLIED" 2>/dev/null | head -n 1)
  if [ -n "$sha" ] && [ "$recorded" = "$sha" ]; then
    VERDICT="already applied" VERDICT_RC=3
    return
  fi
  if why=$(home_git_apply --check "$DIFF" 2>&1); then
    VERDICT="applies cleanly" VERDICT_RC=0
    return
  fi
  if home_git_apply --check -R "$DIFF" >/dev/null 2>&1; then
    VERDICT="already applied" VERDICT_RC=3
    return
  fi
  VERDICT="does not apply: $(printf '%s' "$why" | grep -m 1 . | sed 's/^error: //')" VERDICT_RC=1
}

record_applied() {
  local sha tmp
  sha=$(git hash-object "$DIFF") || return 1
  tmp="$APPLIED.tmp.$$"
  printf 'applied_at=%s\nsha=%s\n' "$(date +%s)" "$sha" >"$tmp" && mv -f -- "$tmp" "$APPLIED"
}

do_show() {
  judge
  if [ "$VERDICT_RC" -eq 4 ]; then
    printf 'home-patch: %s: none\n' "$ID"
    exit 4
  fi
  [ -z "$PATHS" ] || printf 'home-patch: %s: data/%s/home-patch.md changes %s\n' "$ID" "$ID" "$PATHS"
  [ ! -s "$DIFF" ] || cat "$DIFF"
  printf 'home-patch: %s: %s\n' "$ID" "$VERDICT"
  exit "$VERDICT_RC"
}

do_apply() {
  local out
  judge
  case "$VERDICT_RC" in
    4) exit 4 ;;
    3)
      # A patch found applied by its reverse diff gets its record now.
      [ -f "$APPLIED" ] || record_applied || true
      exit 3
      ;;
    1)
      printf 'actionable: home patch data/%s/home-patch.md was not applied (%s); nothing changed - fix it or apply the change by hand, then run bin/fm-home-patch.sh show %s\n' \
        "$ID" "$VERDICT" "$ID" >&2
      exit 1
      ;;
  esac
  if ! out=$(home_git_apply "$DIFF" 2>&1); then
    printf 'actionable: home patch data/%s/home-patch.md was not applied (%s); git apply changes no file when a hunk fails\n' \
      "$ID" "$(printf '%s' "$out" | grep -m 1 . | sed 's/^error: //')" >&2
    exit 1
  fi
  record_applied || printf 'warning: applied the home patch for %s but could not write %s\n' "$ID" "$APPLIED" >&2
  printf 'home-patch: %s: applied to %s\n' "$ID" "$PATHS"
  exit 0
}

do_add() {
  local rel=$3 edited=$4 why rc=0
  why=$(path_refusal "$rel")
  if [ -n "$why" ]; then
    echo "error: $why" >&2
    exit 2
  fi
  [ -f "$edited" ] || { echo "error: edited copy $edited is not a file" >&2; exit 2; }
  diff -u --label "a/$rel" --label "b/$rel" "$HOME_ROOT/$rel" "$edited" >"$WORK/add.diff" || rc=$?
  case "$rc" in
    0) echo "error: $edited does not differ from the home's $rel" >&2; exit 2 ;;
    1) ;;
    *) echo "error: could not diff $rel against $edited" >&2; exit 1 ;;
  esac
  mkdir -p -- "$DATA/$ID" || exit 1
  if [ ! -e "$PATCH" ]; then
    printf '# Home patch for %s\n\nbin/fm-home-patch.sh applies this after the PR lands.\n' "$ID" >"$PATCH" || exit 1
  fi
  { printf '\n```diff\n'; cat "$WORK/add.diff"; printf '```\n'; } >>"$PATCH" || exit 1
  do_show
}

case "$CMD" in
  add) do_add "$@" ;;
  show) do_show ;;
  apply) do_apply ;;
esac

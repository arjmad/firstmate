#!/usr/bin/env bash
# Behavior tests for bin/fm-data-scratch-prune.sh: which nested checkouts a
# task's data folder loses (clean and pushed, innermost first) and which stay
# with their reason (uncommitted, untracked, unpushed, stashed, no remote,
# holding a kept checkout, linked worktrees, borrowed objects, a .git git does
# not own), node_modules and ELF/Mach-O binaries outside every checkout, the
# text and symlinks that always stay, the dry run, and its argument limits.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE="$ROOT/bin/fm-data-scratch-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-data-scratch-prune)
fm_git_identity

put() {  # <file> [content]
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-x}" > "$1"
}

elf() {  # <file>: a stand-in Linux tool binary
  mkdir -p "$(dirname "$1")"
  printf '\177ELF\002\001\001\000payload' > "$1"
}

macho() {  # <file>: a stand-in macOS tool binary
  mkdir -p "$(dirname "$1")"
  printf '\317\372\355\376payload' > "$1"
}

clone() {  # <origin> <dir>
  mkdir -p "$(dirname "$2")"
  git clone -q "$1" "$2"
}

ORIGIN="$TMP_ROOT/origin.git"
fm_git_init_commit "$TMP_ROOT/seed"
git clone -q --bare "$TMP_ROOT/seed" "$ORIGIN"

# make_task <name>: a torn-down task folder holding every kind of scratch and
# every kind of work the prune must keep.
make_task() {
  local d=$TMP_ROOT/$1/data/$1
  put "$d/brief.md" "# Task"
  put "$d/report.md" "# Report"
  put "$d/notes.md" "Noticed: nothing"
  put "$d/shot.png" "not really a png"
  put "$d/answers.json" '{"a":1}'

  clone "$ORIGIN" "$d/clones/clean"
  clone "$ORIGIN" "$d/clones/dirty"
  printf 'edit\n' >> "$d/clones/dirty/README.md"
  put "$d/clones/dirty/node_modules/dep/index.js"
  elf "$d/clones/dirty/bin/tool"
  clone "$ORIGIN" "$d/clones/untracked"
  put "$d/clones/untracked/new-file.txt"
  clone "$ORIGIN" "$d/clones/unpushed"
  printf 'more\n' >> "$d/clones/unpushed/README.md"
  git -C "$d/clones/unpushed" commit -qam unpushed
  clone "$ORIGIN" "$d/clones/stashed"
  printf 'stash me\n' >> "$d/clones/stashed/README.md"
  git -C "$d/clones/stashed" stash -q
  fm_git_init_commit "$d/clones/no-remote"

  # A clean outer clone holding a clean inner clone: both go.
  clone "$ORIGIN" "$d/nest/outer"
  clone "$ORIGIN" "$d/nest/outer/inner"
  # A clean outer clone holding an unpushed inner clone: both stay.
  clone "$ORIGIN" "$d/held/outer"
  clone "$ORIGIN" "$d/held/outer/inner"
  printf 'more\n' >> "$d/held/outer/inner/README.md"
  git -C "$d/held/outer/inner" commit -qam unpushed

  # A clean clone with a linked worktree: the clone and the worktree stay.
  clone "$ORIGIN" "$d/linked/main"
  git -C "$d/linked/main" worktree add -q -b side "$d/linked/side"
  # A clean clone another clone borrows objects from: both stay.
  clone "$ORIGIN" "$d/shared/lender"
  git clone -q --shared "$d/shared/lender" "$d/shared/borrower"
  printf 'more\n' >> "$d/shared/borrower/README.md"
  git -C "$d/shared/borrower" commit -qam unpushed
  # A .git directory git does not own, so it would answer for the enclosing
  # home repository instead.
  mkdir -p "$d/broken/.git"
  put "$d/broken/unique.txt"

  put "$d/web/node_modules/dep/index.js"
  put "$d/web/package.json" '{}'
  mkdir -p "$TMP_ROOT/$1/elsewhere/node_modules"
  ln -s "$TMP_ROOT/$1/elsewhere/node_modules" "$d/linked-modules"
  mkdir -p "$d/aliased"
  ln -s "$TMP_ROOT/$1/elsewhere/node_modules" "$d/aliased/node_modules"
  elf "$d/tools/shellcheck"
  macho "$d/tools/claude-darwin"
  elf "$TMP_ROOT/$1/elsewhere/gbrain"
  ln -s "$TMP_ROOT/$1/elsewhere/gbrain" "$d/tools/gbrain"

  # The home itself is a clean git repository that ignores data/.
  git -C "$TMP_ROOT/$1" init -q -b main
  printf 'data/\nelsewhere/\n' > "$TMP_ROOT/$1/.gitignore"
  git -C "$TMP_ROOT/$1" add .gitignore
  git -C "$TMP_ROOT/$1" commit -qm home
  printf '%s\n' "$d"
}

GONE="clones/clean nest/outer web/node_modules tools/shellcheck tools/claude-darwin"
KEPT="brief.md report.md notes.md shot.png answers.json web/package.json
clones/dirty/README.md clones/dirty/node_modules/dep/index.js clones/dirty/bin/tool
clones/untracked/new-file.txt clones/unpushed/README.md clones/stashed/README.md
clones/no-remote/README.md held/outer/README.md held/outer/inner/README.md
linked/main/README.md linked/side/README.md shared/lender/README.md
shared/borrower/README.md broken/unique.txt linked-modules aliased/node_modules tools/gbrain"

assert_kept() {  # <dir> <msg>
  local f
  for f in $KEPT; do
    [ -e "$1/$f" ] || [ -L "$1/$f" ] || fail "$2: $f was removed"
  done
}

test_real_run_removes_only_reproducible_scratch() {
  local d out rc f
  d=$(make_task real)
  rc=0
  out=$(bash "$PRUNE" "$d" 2>&1) || rc=$?
  expect_code 0 "$rc" "real run"
  for f in $GONE; do
    assert_absent "$d/$f" "real run: $f should be removed: $out"
  done
  assert_kept "$d" "real run"
  assert_absent "$d/nest/outer/inner" "real run: the clean inner clone should go with its clean outer clone"
  assert_present "$TMP_ROOT/real/elsewhere/node_modules" "real run must not follow a node_modules symlink"
  assert_present "$TMP_ROOT/real/elsewhere/gbrain" "real run must not follow a binary symlink"

  assert_contains "$out" "data-scratch: removed checkout real/clones/clean (" "names the clean clone"
  assert_contains "$out" "data-scratch: removed checkout real/nest/outer/inner (" "names the inner clone"
  assert_contains "$out" "data-scratch: removed checkout real/nest/outer (" "names the outer clone"
  assert_contains "$out" "data-scratch: removed node_modules real/web/node_modules (" "names node_modules"
  assert_contains "$out" "data-scratch: removed binary real/tools/shellcheck (" "names the ELF binary"
  assert_contains "$out" "data-scratch: removed binary real/tools/claude-darwin (" "names the Mach-O binary"
  assert_contains "$out" "data-scratch: kept checkout real/clones/dirty: uncommitted changes" "dirty clone reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/untracked: uncommitted changes" "untracked clone reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/unpushed: commits no remote-tracking branch holds" "unpushed reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/stashed: a stash" "stash reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/no-remote: commits no remote-tracking branch holds" "no-remote reason"
  assert_contains "$out" "data-scratch: kept checkout real/held/outer/inner: commits no remote-tracking branch holds" "held inner reason"
  assert_contains "$out" "data-scratch: kept checkout real/held/outer: it holds a kept checkout" "held outer reason"
  assert_contains "$out" "data-scratch: kept checkout real/linked/main: it has linked worktrees" "linked main reason"
  assert_contains "$out" "data-scratch: kept checkout real/linked/side: a linked worktree or submodule" "linked side reason"
  assert_contains "$out" "data-scratch: kept checkout real/shared/lender: another repository borrows its objects" "lender reason"
  assert_contains "$out" "data-scratch: kept checkout real/broken: git does not read it as its own repository" "broken reason"
  assert_contains "$out" "data-scratch: removed 6 items (" "summary counts every removed item"
  assert_contains "$out" " from real/" "summary names the task"
  ! git -C "$d/linked/main" worktree list --porcelain | grep -q prunable \
    || fail "real run left a dangling linked worktree"
  git -C "$d/shared/borrower" fsck >/dev/null 2>&1 || fail "real run broke the borrowing clone"
  pass "real run: clean pushed checkouts, node_modules, and binaries go; work, text, and symlinks stay"
}

test_dry_run_lists_the_same_and_removes_nothing() {
  local d out f
  d=$(make_task dry)
  out=$(bash "$PRUNE" --dry-run "$d" 2>&1)
  for f in $GONE; do
    assert_present "$d/$f" "dry run removed $f"
  done
  assert_kept "$d" "dry run"
  assert_contains "$out" "data-scratch: would remove checkout dry/nest/outer/inner (" "dry run names the inner clone"
  assert_contains "$out" "data-scratch: would remove checkout dry/nest/outer (" "dry run decides the outer clone as the real run would"
  assert_contains "$out" "data-scratch: would remove binary dry/tools/shellcheck (" "dry run names the binary"
  assert_not_contains "$out" "would remove checkout dry/clones/dirty" "dry run keeps the dirty clone"
  assert_contains "$out" "data-scratch: would remove 6 items (" "dry run summary"
  pass "dry run: classifies exactly as a real run and changes nothing"
}

test_nothing_to_do_and_bad_arguments() {
  local d out rc
  d="$TMP_ROOT/plain/data/plain"
  put "$d/brief.md"
  put "$d/report.md"
  out=$(bash "$PRUNE" "$d" 2>&1)
  assert_equals "" "$out" "a folder with no scratch prints nothing"
  out=$(bash "$PRUNE" "$TMP_ROOT/missing" 2>&1)
  assert_equals "" "$out" "a missing folder prints nothing"

  d="$TMP_ROOT/self/data/self"
  clone "$ORIGIN" "$d"
  elf "$d/tool"
  out=$(bash "$PRUNE" "$d" 2>&1)
  assert_equals "" "$out" "a task folder that is itself a checkout is left alone"
  assert_present "$d/tool" "a task folder that is itself a checkout is left alone"

  rc=0
  bash "$PRUNE" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no folder"
  rc=0
  bash "$PRUNE" --bogus "$d" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unknown option"
  rc=0
  bash "$PRUNE" "$d" "$d" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "two folders"
  pass "no scratch, a missing folder, and a checkout task folder change nothing; bad arguments exit 2"
}

test_real_run_removes_only_reproducible_scratch
test_dry_run_lists_the_same_and_removes_nothing
test_nothing_to_do_and_bad_arguments

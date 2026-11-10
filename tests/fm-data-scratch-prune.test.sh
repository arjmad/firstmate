#!/usr/bin/env bash
# Behavior tests for bin/fm-data-scratch-prune.sh: which nested checkouts a
# task's data folder loses (clean and pushed, innermost first) and which stay
# with their reason (uncommitted, untracked, unpushed, stashed, no remote,
# holding a kept checkout, linked worktrees, borrowed objects, a .git git does
# not own), dependency folders (node_modules, a .venv with pyvenv.cfg, a dist
# beside a package manifest unless it holds an image or PDF) and ELF/Mach-O
# binaries outside every checkout, the text and symlinks that always stay, the
# dry run, --keep-binaries, and its argument limits.
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

elf() {  # <file> [e_type octal]: a stand-in Linux ELF, an executable by default
  mkdir -p "$(dirname "$1")"
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000' > "$1"
  printf '%b' "\\0${2:-002}\\000payload" >> "$1"
}

macho() {  # <file>: a stand-in macOS tool binary (64-bit executable)
  mkdir -p "$(dirname "$1")"
  printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000payload' > "$1"
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
  # Work reachable only from a local tag.
  clone "$ORIGIN" "$d/clones/tagged"
  printf 'tagged\n' >> "$d/clones/tagged/README.md"
  git -C "$d/clones/tagged" commit -qam tagged
  git -C "$d/clones/tagged" tag keep-me
  git -C "$d/clones/tagged" reset -q --hard origin/main
  # A git dependency with unlanded work inside node_modules keeps the folder,
  # and so does a node_modules that is itself a dirty checkout.
  clone "$ORIGIN" "$d/gitdep/node_modules/dep"
  printf 'more\n' >> "$d/gitdep/node_modules/dep/README.md"
  git -C "$d/gitdep/node_modules/dep" commit -qam unpushed
  put "$d/gitdep/node_modules/other/index.js"
  clone "$ORIGIN" "$d/vendored/node_modules"
  printf 'edit\n' >> "$d/vendored/node_modules/README.md"

  # A clean outer clone holding a clean inner clone: both go.
  clone "$ORIGIN" "$d/nest/outer"
  clone "$ORIGIN" "$d/nest/outer/inner"
  # A clean outer clone holding a clean inner clone whose name needs quoting.
  clone "$ORIGIN" "$d/nest/quoted"
  clone "$ORIGIN" "$d/nest/quoted/in ner"
  # An unpushed outer clone keeps the clean clone inside it.
  clone "$ORIGIN" "$d/nest/unpushed"
  printf 'more\n' >> "$d/nest/unpushed/README.md"
  git -C "$d/nest/unpushed" commit -qam unpushed
  clone "$ORIGIN" "$d/nest/unpushed/inner"
  # A clean clone whose remote is another clone in the same task folder.
  clone "$d/clones/clean" "$d/clones/of-clean"
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
  # A name holding a newline must never make its first line a deletion target.
  put "$d/we/keep.txt"
  put "$d/we
ird/node_modules/dep/index.js"
  put "$d/web/package.json" '{}'
  mkdir -p "$TMP_ROOT/$1/elsewhere/node_modules"
  ln -s "$TMP_ROOT/$1/elsewhere/node_modules" "$d/linked-modules"
  mkdir -p "$d/aliased"
  ln -s "$TMP_ROOT/$1/elsewhere/node_modules" "$d/aliased/node_modules"
  elf "$d/tools/shellcheck"
  elf "$d/crash/core.1234" 004
  elf "$d/build/main.o" 001
  mkdir -p "$d/java"
  printf '\312\376\272\276\000\000\000\101payload-payload' > "$d/java/Main.class"
  macho "$d/tools/claude-darwin"
  elf "$TMP_ROOT/$1/elsewhere/gbrain"
  # A Python virtual environment goes whole, its shared libraries with it; a
  # .venv with no pyvenv.cfg is not one and stays.
  put "$d/py/pyproject.toml" '[project]'
  put "$d/py/.venv/pyvenv.cfg" 'home = /usr/bin'
  elf "$d/py/.venv/lib/native.so" 003
  put "$d/notvenv/.venv/data.txt"
  # Build output beside its manifest goes; one holding a PDF or an image, and
  # a dist with no manifest beside it, stay.
  put "$d/site/package.json" '{}'
  put "$d/site/dist/app.js"
  put "$d/brochure/package.json" '{}'
  put "$d/brochure/dist/brochure.pdf"
  put "$d/logo/setup.py"
  put "$d/logo/dist/assets/Logo.PNG"
  put "$d/loose/dist/tool.txt"
  put "$d/loose/dist/site/node_modules/dep/index.js"
  ln -s "$TMP_ROOT/$1/elsewhere/gbrain" "$d/tools/gbrain"

  # The home itself is a clean git repository that ignores data/.
  git -C "$TMP_ROOT/$1" init -q -b main
  printf 'data/\nelsewhere/\n' > "$TMP_ROOT/$1/.gitignore"
  git -C "$TMP_ROOT/$1" add .gitignore
  git -C "$TMP_ROOT/$1" commit -qm home
  printf '%s\n' "$d"
}

GONE="clones/clean nest/outer nest/quoted web/node_modules py/.venv site/dist loose/dist/site/node_modules tools/shellcheck tools/claude-darwin"
KEPT="brief.md report.md notes.md shot.png answers.json web/package.json
clones/dirty/README.md clones/dirty/node_modules/dep/index.js clones/dirty/bin/tool
clones/untracked/new-file.txt clones/unpushed/README.md clones/stashed/README.md
clones/no-remote/README.md clones/tagged/README.md gitdep/node_modules/dep/README.md
gitdep/node_modules/other/index.js vendored/node_modules/README.md held/outer/README.md held/outer/inner/README.md
linked/main/README.md linked/side/README.md shared/lender/README.md
shared/borrower/README.md broken/unique.txt clones/of-clean/README.md
nest/unpushed/README.md nest/unpushed/inner/README.md crash/core.1234 build/main.o java/Main.class linked-modules aliased/node_modules tools/gbrain
py/pyproject.toml notvenv/.venv/data.txt site/package.json brochure/dist/brochure.pdf logo/dist/assets/Logo.PNG loose/dist/tool.txt"

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
  assert_present "$TMP_ROOT/real/elsewhere/node_modules" "real run must not follow a node_modules symlink"
  assert_present "$TMP_ROOT/real/elsewhere/gbrain" "real run must not follow a binary symlink"

  assert_contains "$out" "data-scratch: removed checkout real/nest/outer (" "names the outer clone"
  assert_not_contains "$out" "real/nest/outer/inner" "the inner clone goes with its outer clone, unnamed"
  assert_contains "$out" "data-scratch: removed checkout real/nest/quoted (" "a quoted inner name still lets its outer clone go"
  assert_contains "$out" "data-scratch: kept checkout real/nest/unpushed: commits no remote-tracking branch holds" "unpushed outer reason"
  assert_contains "$out" "data-scratch: kept checkout real/nest/unpushed/inner: it is inside a kept checkout" "a clean clone inside a kept one stays"
  assert_contains "$out" "data-scratch: removed checkout real/clones/clean (" "names the clean clone"
  assert_contains "$out" "data-scratch: kept checkout real/clones/of-clean: its remote is inside this task folder" "a clone of a task-local clone stays"
  assert_not_contains "$out" "core.1234" "a core dump is not a tool binary"
  assert_not_contains "$out" "main.o" "an object file is not a tool binary"
  assert_not_contains "$out" "Main.class" "a Java class is not a tool binary"
  assert_contains "$out" "data-scratch: removed node_modules real/web/node_modules (" "names node_modules"
  assert_contains "$out" "data-scratch: removed binary real/tools/shellcheck (" "names the ELF binary"
  assert_contains "$out" "data-scratch: removed binary real/tools/claude-darwin (" "names the Mach-O binary"
  assert_contains "$out" "data-scratch: kept checkout real/clones/dirty: uncommitted changes" "dirty clone reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/untracked: uncommitted changes" "untracked clone reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/unpushed: commits no remote-tracking branch holds" "unpushed reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/stashed: a stash" "stash reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/no-remote: commits no remote-tracking branch holds" "no-remote reason"
  assert_contains "$out" "data-scratch: kept checkout real/clones/tagged: commits no remote-tracking branch holds" "tagged reason"
  assert_contains "$out" "data-scratch: kept checkout real/gitdep/node_modules/dep: commits no remote-tracking branch holds" "git dependency reason"
  assert_contains "$out" "data-scratch: kept node_modules real/gitdep/node_modules: it holds a kept checkout" "node_modules holding work"
  assert_contains "$out" "data-scratch: kept checkout real/vendored/node_modules: uncommitted changes" "node_modules checkout reason"
  assert_not_contains "$out" "removed node_modules real/vendored/node_modules" "a node_modules checkout is not removed as node_modules"
  assert_contains "$out" "data-scratch: kept checkout real/held/outer/inner: commits no remote-tracking branch holds" "held inner reason"
  assert_contains "$out" "data-scratch: kept checkout real/held/outer: it holds a kept checkout" "held outer reason"
  assert_contains "$out" "data-scratch: kept checkout real/linked/main: it has linked worktrees" "linked main reason"
  assert_contains "$out" "data-scratch: kept checkout real/linked/side: a linked worktree or submodule" "linked side reason"
  assert_contains "$out" "data-scratch: kept checkout real/shared/lender: another repository borrows its objects" "lender reason"
  assert_contains "$out" "data-scratch: kept checkout real/broken: git does not read it as its own repository" "broken reason"
  assert_contains "$out" "data-scratch: removed venv real/py/.venv (" "names the virtual environment"
  assert_contains "$out" "data-scratch: removed dist real/site/dist (" "names the build output"
  assert_contains "$out" "data-scratch: kept dist real/brochure/dist: it holds images or PDFs" "a dist holding a PDF stays"
  assert_contains "$out" "data-scratch: kept dist real/logo/dist: it holds images or PDFs" "a dist holding an image stays"
  assert_not_contains "$out" "native.so" "a library inside a removed venv is not counted again as a binary"
  assert_not_contains "$out" "dist real/loose/dist" "a dist with no manifest is not a dependency folder"
  assert_contains "$out" "data-scratch: removed node_modules real/loose/dist/site/node_modules (" "a node_modules inside a plain dist is still found"
  assert_not_contains "$out" "notvenv" "a .venv with no pyvenv.cfg is not a dependency folder"
  assert_contains "$out" "data-scratch: removed 9 items (" "summary counts every removed item"
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
  assert_contains "$out" "data-scratch: would remove checkout dry/nest/quoted (" "dry run decides a quoted inner name as the real run does"
  assert_contains "$out" "data-scratch: would remove checkout dry/nest/outer (" "dry run decides the outer clone as the real run would"
  assert_contains "$out" "data-scratch: would remove binary dry/tools/shellcheck (" "dry run names the binary"
  assert_not_contains "$out" "would remove checkout dry/clones/dirty" "dry run keeps the dirty clone"
  assert_contains "$out" "data-scratch: would remove 9 items (" "dry run summary"
  pass "dry run: classifies exactly as a real run and changes nothing"
}

test_keep_binaries_removes_only_checkouts_and_dependency_folders() {
  local d out f
  d=$(make_task keepbin)
  out=$(bash "$PRUNE" --keep-binaries "$d" 2>&1)
  for f in clones/clean nest/outer nest/quoted web/node_modules py/.venv site/dist loose/dist/site/node_modules; do
    assert_absent "$d/$f" "--keep-binaries: $f should be removed: $out"
  done
  assert_present "$d/tools/shellcheck" "--keep-binaries keeps the ELF binary"
  assert_present "$d/tools/claude-darwin" "--keep-binaries keeps the Mach-O binary"
  assert_kept "$d" "--keep-binaries"
  assert_not_contains "$out" " binary " "--keep-binaries names no binary"
  assert_contains "$out" "data-scratch: removed 7 items (" "--keep-binaries summary"
  pass "--keep-binaries: clean checkouts and dependency folders go; binaries, work, and text stay"
}

test_unreadable_dist_stays() {
  local d out
  [ "$(id -u)" -ne 0 ] || { pass "skip: root reads every folder, so an unreadable dist cannot be built"; return; }
  d="$TMP_ROOT/unreadable/data/unreadable"
  put "$d/brief.md"
  put "$d/site/package.json" '{}'
  put "$d/site/dist/app.js"
  put "$d/site/dist/locked/maybe.pdf"
  chmod 000 "$d/site/dist/locked"
  out=$(bash "$PRUNE" "$d" 2>&1)
  chmod 755 "$d/site/dist/locked"
  assert_present "$d/site/dist/app.js" "a dist the scan could not read must stay: $out"
  assert_contains "$out" "data-scratch: kept dist unreadable/site/dist: it holds images or PDFs" "the kept dist is named"
  pass "a dist whose image and PDF scan fails stays"
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
test_keep_binaries_removes_only_checkouts_and_dependency_folders
test_unreadable_dist_stays
test_nothing_to_do_and_bad_arguments

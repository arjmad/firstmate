#!/usr/bin/env bash
# bin/fm-home-patch.sh: a ship's home-file change recorded as one diff in
# data/<id>/home-patch.md, shown with a verdict, and applied once to the home's
# data/ or config/ - whether the home is a git checkout, nested in one, or
# neither - while every path or shape it may not change, and a drifted file,
# changes nothing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-patch)
PATCHER="$ROOT/bin/fm-home-patch.sh"

make_home() {  # <dir>
  mkdir -p "$1/data" "$1/config" "$1/state"
  printf '%s\n' '# Learnings' 'old line' '```' 'fenced' '```' > "$1/data/learnings.md"
  printf '%s\n' '# read by fm-spawn once worker-compact-window-1112 lands' '400000' > "$1/config/crew-compact-window"
  printf '%s\n' '# Captain' 'a ruling' > "$1/data/captain.md"
  printf '%s\n' 'one' > "$1/state/thing"
}

in_home() {  # <home> <command> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$@"
}

# Records an edit of <rel> whose new content is the rest of the arguments.
add_edit() {  # <home> <id> <rel> <line>...
  local home=$1 id=$2 rel=$3 copy
  shift 3
  copy="$TMP_ROOT/edit.$$.$RANDOM"
  printf '%s\n' "$@" > "$copy"
  in_home "$home" bash "$PATCHER" add "$id" "$rel" "$copy" >/dev/null 2>&1
}

# Writes a home patch holding exactly <diff-file> in one diff block.
write_patch() {  # <home> <id> <diff-file>
  mkdir -p "$1/data/$2"
  { printf '# Home patch\n\n```diff\n'; cat "$3"; printf '```\n'; } > "$1/data/$2/home-patch.md"
}

expect_code() {  # <want> <got> <message>
  [ "$1" = "$2" ] || fail "$3 (exit $2, want $1)"
}

test_add_show_apply_once() {
  local home="$TMP_ROOT/once" out rc
  make_home "$home"
  add_edit "$home" ship-1 data/learnings.md '# Learnings' 'new line' '```' 'fenced' '```' \
    || fail "add refused a data/ edit"
  add_edit "$home" ship-1 config/crew-compact-window '# read by fm-spawn' '400000' \
    || fail "add refused a config/ edit"
  grep -qx 'old line' "$home/data/learnings.md" || fail "add edited the live home file"
  out=$(in_home "$home" bash "$PATCHER" show ship-1 2>&1); rc=$?
  expect_code 0 "$rc" "show did not report a clean patch"
  printf '%s\n' "$out" | grep -qx 'home-patch: ship-1: applies cleanly' || fail "show printed no clean verdict: $out"
  printf '%s\n' "$out" | grep -qx '+new line' || fail "show did not print the diff: $out"
  out=$(in_home "$home" bash "$PATCHER" apply ship-1 2>&1); rc=$?
  expect_code 0 "$rc" "apply did not apply a clean patch: $out"
  printf '%s\n' "$out" | grep -qx 'home-patch: ship-1: applied to data/learnings.md, config/crew-compact-window' \
    || fail "apply did not name both files: $out"
  grep -qx 'new line' "$home/data/learnings.md" || fail "the data/ edit did not land"
  grep -qx '```' "$home/data/learnings.md" || fail "a fence line in the edited text was lost"
  grep -qx '# read by fm-spawn' "$home/config/crew-compact-window" || fail "the config/ edit did not land"
  grep -q '^sha=' "$home/data/ship-1/home-patch.applied" || fail "no applied record was written"
  out=$(in_home "$home" bash "$PATCHER" apply ship-1 2>&1); rc=$?
  expect_code 3 "$rc" "a second apply was not a no-op"
  [ -z "$out" ] || fail "a second apply printed something: $out"
  out=$(in_home "$home" bash "$PATCHER" show ship-1 2>&1)
  printf '%s\n' "$out" | grep -qx 'home-patch: ship-1: already applied' || fail "show did not say already applied: $out"
  pass "add records a diff without editing the home, and apply lands it once"
}

test_hand_applied_patch_is_recognised() {
  local home="$TMP_ROOT/hand" rc
  make_home "$home"
  add_edit "$home" ship-2 data/learnings.md '# Learnings' 'new line' '```' 'fenced' '```' || fail "add refused"
  printf '%s\n' '# Learnings' 'new line' '```' 'fenced' '```' > "$home/data/learnings.md"
  in_home "$home" bash "$PATCHER" apply ship-2 >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "a patch already applied by hand was not recognised"
  [ -f "$home/data/ship-2/home-patch.applied" ] || fail "the hand-applied patch got no applied record"
  pass "a patch already applied by hand is a no-op that gets its record"
}

test_home_location_does_not_move_paths() {
  local outer="$TMP_ROOT/outer" top="$TMP_ROOT/top" bare="$TMP_ROOT/bare" home rc
  fm_git_init_commit "$top"
  make_home "$top"
  fm_git_init_commit "$outer"
  make_home "$outer/nested/home"
  make_home "$bare"
  for home in "$top" "$outer/nested/home" "$bare"; do
    add_edit "$home" ship-3 data/learnings.md '# Learnings' 'moved' '```' 'fenced' '```' || fail "add refused in $home"
    in_home "$home" bash "$PATCHER" apply ship-3 >/dev/null 2>&1; rc=$?
    expect_code 0 "$rc" "apply failed for the home at $home"
    grep -qx 'moved' "$home/data/learnings.md" || fail "the edit missed the home at $home"
  done
  [ ! -e "$outer/data" ] || fail "a nested home's patch landed in the enclosing checkout"
  pass "a home at a checkout top, nested in a checkout, or outside one is the diff's root"
}

test_drift_changes_nothing() {
  local home="$TMP_ROOT/drift" out rc
  make_home "$home"
  add_edit "$home" ship-4 data/learnings.md '# Learnings' 'new line' '```' 'fenced' '```' || fail "add refused"
  add_edit "$home" ship-4 config/crew-compact-window '# new comment' '400000' || fail "add refused"
  printf '%s\n' '# Learnings' 'someone else edited this' '```' 'fenced' '```' > "$home/data/learnings.md"
  out=$(in_home "$home" bash "$PATCHER" apply ship-4 2>&1); rc=$?
  expect_code 1 "$rc" "a drifted patch did not refuse"
  printf '%s\n' "$out" | grep -q '^actionable: home patch data/ship-4/home-patch.md was not applied (does not apply' \
    || fail "a drifted patch printed no actionable line: $out"
  grep -qx '# read by fm-spawn once worker-compact-window-1112 lands' "$home/config/crew-compact-window" \
    || fail "the clean hunk of a drifted patch was applied"
  [ ! -e "$home/data/ship-4/home-patch.applied" ] || fail "a drifted patch was recorded applied"
  [ -f "$home/data/ship-4/home-patch.md" ] || fail "a drifted patch was removed"
  pass "a drifted patch changes no file, keeps the patch and prints one actionable line"
}

# Each refused shape: apply exits 1 with a refused verdict and changes nothing.
expect_refused() {  # <home> <id> <message>
  local out rc before
  before=$(cat "$1/data/learnings.md" "$1/config/crew-compact-window" "$1/data/captain.md" "$1/state/thing" 2>/dev/null)
  out=$(in_home "$1" bash "$PATCHER" show "$2" 2>&1); rc=$?
  expect_code 1 "$rc" "$3: show did not refuse"
  printf '%s\n' "$out" | grep -q "^home-patch: $2: refused: " || fail "$3: no refused verdict: $out"
  in_home "$1" bash "$PATCHER" apply "$2" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "$3: apply did not refuse"
  [ "$before" = "$(cat "$1/data/learnings.md" "$1/config/crew-compact-window" "$1/data/captain.md" "$1/state/thing" 2>/dev/null)" ] \
    || fail "$3: a refused patch changed a file"
}

test_paths_and_shapes_it_may_not_change() {
  local home="$TMP_ROOT/refuse" d="$TMP_ROOT/diffs" rc
  make_home "$home"
  mkdir -p "$d"
  printf '%s\n' '--- a/state/thing' '+++ b/state/thing' '@@ -1 +1 @@' '-one' '+two' > "$d/state.diff"
  write_patch "$home" r-state "$d/state.diff"
  expect_refused "$home" r-state "a state/ path"
  printf '%s\n' '--- a/data/captain.md' '+++ b/data/captain.md' '@@ -1,2 +1,2 @@' ' # Captain' '-a ruling' '+a forged ruling' > "$d/captain.diff"
  write_patch "$home" r-captain "$d/captain.diff"
  expect_refused "$home" r-captain "the captain's rulings"
  printf '%s\n' '--- a/data/../state/thing' '+++ b/data/../state/thing' '@@ -1 +1 @@' '-one' '+two' > "$d/dotdot.diff"
  write_patch "$home" r-dotdot "$d/dotdot.diff"
  expect_refused "$home" r-dotdot "a .. component"
  printf '%s\n' 'diff --git a/data/new.md b/data/new.md' 'new file mode 100644' '--- /dev/null' '+++ b/data/new.md' '@@ -0,0 +1 @@' '+hello' > "$d/create.diff"
  write_patch "$home" r-create "$d/create.diff"
  expect_refused "$home" r-create "a created file"
  [ ! -e "$home/data/new.md" ] || fail "a create patch created its file"
  printf '%s\n' 'diff --git a/config/crew-compact-window b/config/crew-compact-window' 'old mode 100644' 'new mode 100755' > "$d/mode.diff"
  write_patch "$home" r-mode "$d/mode.diff"
  expect_refused "$home" r-mode "a mode change"
  mkdir -p "$home/elsewhere"
  printf '%s\n' 'one' > "$home/elsewhere/target"
  ln -s ../elsewhere/target "$home/data/link.md"
  printf '%s\n' '--- a/data/link.md' '+++ b/data/link.md' '@@ -1 +1 @@' '-one' '+two' > "$d/link.diff"
  write_patch "$home" r-link "$d/link.diff"
  expect_refused "$home" r-link "a symlinked file"
  grep -qx one "$home/elsewhere/target" || fail "a patch wrote through a symlink"
  ln -s ../elsewhere "$home/data/linkdir"
  printf '%s\n' '--- a/data/linkdir/target' '+++ b/data/linkdir/target' '@@ -1 +1 @@' '-one' '+two' > "$d/linkdir.diff"
  write_patch "$home" r-linkdir "$d/linkdir.diff"
  expect_refused "$home" r-linkdir "a symlinked directory"
  grep -qx one "$home/elsewhere/target" || fail "a patch wrote through a symlinked directory"
  mkdir -p "$home/data/r-open"
  printf '%s\n' '# Home patch' '```diff' '--- a/data/learnings.md' > "$home/data/r-open/home-patch.md"
  expect_refused "$home" r-open "an unclosed block"
  mkdir -p "$home/data/r-empty"
  printf '%s\n' '# Home patch' 'no diff here' > "$home/data/r-empty/home-patch.md"
  expect_refused "$home" r-empty "a file with no diff block"
  printf '%s\n' 'one' > "$TMP_ROOT/abs-copy"
  in_home "$home" bash "$PATCHER" add r-add state/thing "$TMP_ROOT/abs-copy" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "add accepted a state/ path"
  pass "state/, the captain's rulings, .., create, mode change, symlinks and malformed files are refused"
}

test_no_patch_and_bad_arguments() {
  local home="$TMP_ROOT/none" out rc
  make_home "$home"
  out=$(in_home "$home" bash "$PATCHER" show nothing-here 2>&1); rc=$?
  expect_code 4 "$rc" "show of no patch"
  [ "$out" = 'home-patch: nothing-here: none' ] || fail "show of no patch printed: $out"
  out=$(in_home "$home" bash "$PATCHER" apply nothing-here 2>&1); rc=$?
  expect_code 4 "$rc" "apply of no patch"
  [ -z "$out" ] || fail "apply of no patch printed: $out"
  for args in "apply ../evil" "show" "apply a b" "frob ship"; do
    # shellcheck disable=SC2086 # Word splitting builds each refused argument set.
    in_home "$home" bash "$PATCHER" $args >/dev/null 2>&1; rc=$?
    expect_code 2 "$rc" "a malformed argument set: '$args'"
  done
  pass "no patch is a quiet exit 4 and a malformed argument exits 2"
}

fm_test_run \
  test_add_show_apply_once \
  test_hand_applied_patch_is_recognised \
  test_home_location_does_not_move_paths \
  test_drift_changes_nothing \
  test_paths_and_shapes_it_may_not_change \
  test_no_patch_and_bad_arguments

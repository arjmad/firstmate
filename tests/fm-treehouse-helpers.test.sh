#!/usr/bin/env bash
# Behavior tests for tests/treehouse-helpers.sh, the helper that keeps a
# real-Treehouse test's pools out of the fleet's pool storage: resolving that
# storage the way Treehouse does, pointing TREEHOUSE_ROOT inside the test root,
# refusing a worktree outside it, and reporting any production slot whose git
# link points into the test root. Every case runs under a fake HOME, so the
# real user's Treehouse config and pools are never read or written; the last
# case proves the override against a real Treehouse where one is installed.
# shellcheck disable=SC2016 # each in_home script expands its own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-helpers)

# in_home <home> <script> [args...]: run <script> in a fresh bash with the
# helper sourced, HOME set to <home>, and no inherited TREEHOUSE_ROOT; the
# script reads [args...] as $1, $2, ...
in_home() {
  local home=$1 script=$2
  shift 2
  env -u TREEHOUSE_ROOT HOME="$home" bash -c '. "$0" || exit 1; '"$script" \
    "$ROOT/tests/treehouse-helpers.sh" "$@"
}

write_config() {  # <home> <root-value>
  mkdir -p "$1/.config/treehouse"
  printf '# fixture\nmax_trees = 8\nroot = "%s"\n' "$2" > "$1/.config/treehouse/config.toml"
}

# --- production storage resolution -------------------------------------------

HOME_NONE="$TMP_ROOT/home-none"; mkdir -p "$HOME_NONE"
assert_equals "$HOME_NONE/.treehouse" "$(in_home "$HOME_NONE" treehouse_test_production_storage)" \
  "with no config, production storage is \$HOME/.treehouse"

HOME_ABS="$TMP_ROOT/home-abs"; write_config "$HOME_ABS" "$TMP_ROOT/fleet-root/"
assert_equals "$TMP_ROOT/fleet-root/.treehouse" "$(in_home "$HOME_ABS" treehouse_test_production_storage)" \
  "an absolute config root names production storage"

HOME_TILDE="$TMP_ROOT/home-tilde"; write_config "$HOME_TILDE" \~/worktrees
assert_equals "$HOME_TILDE/worktrees/.treehouse" "$(in_home "$HOME_TILDE" treehouse_test_production_storage)" \
  "a home-relative config root expands against HOME"

HOME_SQ="$TMP_ROOT/home-sq"; mkdir -p "$HOME_SQ/.config/treehouse"
printf "root = '%s'\n" "$TMP_ROOT/sq-root" > "$HOME_SQ/.config/treehouse/config.toml"
assert_equals "$TMP_ROOT/sq-root/.treehouse" "$(in_home "$HOME_SQ" treehouse_test_production_storage)" \
  "a single-quoted config root names production storage"

HOME_TABLE="$TMP_ROOT/home-table"; mkdir -p "$HOME_TABLE/.config/treehouse"
printf 'max_trees = 8\n\n[hooks]\nroot = "%s"\n' "$TMP_ROOT/table-root" > "$HOME_TABLE/.config/treehouse/config.toml"
assert_equals "$HOME_TABLE/.treehouse" "$(in_home "$HOME_TABLE" treehouse_test_production_storage)" \
  "a root key under another table is not the top-level root"

HOME_REL="$TMP_ROOT/home-rel"; write_config "$HOME_REL" "."
assert_equals "" "$(in_home "$HOME_REL" treehouse_test_production_storage)" \
  "an in-project config root has no single production storage"

assert_equals "$TMP_ROOT/env-root/.treehouse" \
  "$(in_home "$HOME_ABS" 'TREEHOUSE_ROOT=$1 treehouse_test_production_storage' "$TMP_ROOT/env-root")" \
  "a caller's TREEHOUSE_ROOT outranks the config root"
pass "production pool storage resolves in Treehouse's own precedence order"

# --- isolation and the worktree check ------------------------------------------

CASE_ROOT="$TMP_ROOT/case-isolate"; mkdir -p "$CASE_ROOT"
OUT=$(in_home "$HOME_ABS" 'treehouse_test_isolate "$1" || exit 1
printf "%s\n%s\n" "$TREEHOUSE_TEST_ROOT" "$TREEHOUSE_TEST_PRODUCTION_STORAGE"
env | grep "^TREEHOUSE_ROOT="' "$CASE_ROOT") || fail "isolate failed"
assert_equals "$CASE_ROOT/treehouse
$TMP_ROOT/fleet-root/.treehouse
TREEHOUSE_ROOT=$CASE_ROOT/treehouse" "$OUT" \
  "isolate exports the test-owned root and remembers the storage it replaced"
[ -d "$CASE_ROOT/treehouse" ] || fail "isolate did not create the test-owned root"

in_home "$HOME_ABS" 'treehouse_test_isolate "$1" && treehouse_test_require_isolated_worktree "$1/treehouse/.treehouse/project-abc123/1/project"' \
  "$CASE_ROOT" >/dev/null || fail "a worktree under the isolated root was refused"
if OUT=$(in_home "$HOME_ABS" 'treehouse_test_isolate "$1" && treehouse_test_require_isolated_worktree "$2"' \
  "$CASE_ROOT" "$TMP_ROOT/fleet-root/.treehouse/project-abc123/1/project"); then
  fail "a worktree in production storage was accepted"
fi
assert_contains "$OUT" "outside the isolated Treehouse root" "the refusal names why"
pass "isolation exports a test-owned root and refuses a worktree outside it"

# --- production slot scan ---------------------------------------------------------

make_slot() {  # <storage> <pool> <slot> <gitdir>
  mkdir -p "$1/$2/$3/repo"
  printf 'gitdir: %s\n' "$4" > "$1/$2/$3/repo/.git"
}
SCAN_ROOT="$TMP_ROOT/case-scan"; mkdir -p "$SCAN_ROOT"
PROD="$TMP_ROOT/fleet-root/.treehouse"
make_slot "$PROD" fleet-aaaaaa 1 "$TMP_ROOT/fleet-repo/.git/worktrees/repo"
make_slot "$PROD" sibling-bbbbbb 1 "$SCAN_ROOT-sibling/repo/.git/worktrees/repo"

scan() {  # <home>
  in_home "$1" 'treehouse_test_isolate "$1" && treehouse_test_production_slots "$1"' "$SCAN_ROOT"
}
OUT=$(scan "$HOME_ABS") || fail "a clean production storage reported leaked slots: $OUT"
assert_equals "" "$OUT" "slots owned by other repositories, including a same-prefix sibling, are not attributed to the test"

make_slot "$PROD" project-cccccc 1 "$SCAN_ROOT/project/.git/worktrees/project"
make_slot "$PROD" project-cccccc 2 "$SCAN_ROOT/project/.git/worktrees/project1"
if OUT=$(scan "$HOME_ABS"); then
  fail "leaked test slots in production storage passed the scan"
fi
assert_equals "$PROD/project-cccccc/1/repo
$PROD/project-cccccc/2/repo" "$OUT" "the scan lists exactly the slots linked into the test root"

OUT=$(scan "$HOME_REL") || fail "an unresolvable production storage failed the scan"
assert_equals "" "$OUT" "an unresolvable production storage reports nothing"
pass "the production scan reports exactly the slots linked into the test root"

# --- real Treehouse honors the isolation ------------------------------------------

if ! command -v treehouse >/dev/null 2>&1; then
  echo "skip: treehouse not found (real-Treehouse isolation case)"
  exit 0
fi
TREEHOUSE_VERSION=$(treehouse --version 2>/dev/null | head -n 1)
REAL_HOME="$TMP_ROOT/home-real"; write_config "$REAL_HOME" "$TMP_ROOT/real-fleet-root"
REAL_ROOT="$TMP_ROOT/case-real"
fm_git_init_commit "$REAL_ROOT/repo"
in_home "$REAL_HOME" 'treehouse_test_isolate "$1" && cd "$1/repo" && treehouse status --json >/dev/null' "$REAL_ROOT" \
  || fail "treehouse status failed under the isolated root"
compgen -G "$REAL_ROOT/treehouse/.treehouse/repo-*" >/dev/null \
  || fail "Treehouse $TREEHOUSE_VERSION did not create the pool under the isolated root"
[ ! -e "$TMP_ROOT/real-fleet-root" ] \
  || fail "Treehouse $TREEHOUSE_VERSION wrote into the configured fleet root despite TREEHOUSE_ROOT"
pass "real Treehouse $TREEHOUSE_VERSION keeps the pool under the isolated root and out of the configured fleet root"

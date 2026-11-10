#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-store-prune.sh: which Claude project entries
# go (absolute paths that do not exist) and which stay (existing paths,
# dangling symlinks, relative keys, every other part of the store), the dry
# run, the dated backup a --missing run writes first, the single-entry --path
# mode teardown uses, a symlinked store, and its refusals. Every store here is
# a throwaway CLAUDE_CONFIG_DIR or HOME.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE="$ROOT/bin/fm-claude-store-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-store-prune)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# new_store <name>: a throwaway config dir whose store names one existing
# folder, two gone ones, a dangling symlink, and a relative key. Echoes the dir.
new_store() {
  local c=$TMP_ROOT/$1
  mkdir -p "$c/config" "$c/exists"
  ln -s "$c/nowhere" "$c/dangling"
  cat > "$c/config/.claude.json" <<EOF
{
  "numStartups": 7,
  "projects": {
    "$c/exists": { "hasTrustDialogAccepted": true },
    "$c/gone": { "hasTrustDialogAccepted": true },
    "$c/gone-too/sub": { "allowedTools": [] },
    "$c/dangling": { "hasTrustDialogAccepted": true },
    "relative/key": {}
  },
  "oauthAccount": { "emailAddress": "someone@example.invalid" }
}
EOF
  chmod 600 "$c/config/.claude.json"
  printf '%s\n' "$c"
}

run_prune() {  # <config-dir> [args...]
  local dir=$1
  shift
  CLAUDE_CONFIG_DIR="$dir" bash "$PRUNE" "$@" 2>&1
}

keys() {  # <store>: its project keys, sorted
  node -e 'const j = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    console.log(Object.keys(j.projects || {}).sort().join("\n"))' "$1"
}

backups() {  # <config-dir>: how many dated backups sit beside the store
  find "$1" -maxdepth 1 -name '.claude.json.fm-prune-backup-*' | wc -l | tr -d ' '
}

test_dry_run_lists_dead_entries_and_changes_nothing() {
  local c before out
  c=$(new_store dry)
  before=$(cat "$c/config/.claude.json")
  out=$(run_prune "$c/config" --dry-run --missing)
  assert_contains "$out" "would remove: $c/gone" "dry run names a gone folder"
  assert_contains "$out" "would remove: $c/gone-too/sub" "dry run names a gone nested folder"
  assert_not_contains "$out" "would remove: $c/exists" "an existing folder stays"
  assert_not_contains "$out" "dangling" "a dangling symlink is not proof the path is gone"
  assert_not_contains "$out" "relative/key" "a relative key stays"
  assert_contains "$out" "claude store: would remove 2 of 5 project entries from $c/config/.claude.json" "dry run summary"
  assert_equals "$before" "$(cat "$c/config/.claude.json")" "a dry run leaves the store byte for byte"
  assert_equals 0 "$(backups "$c/config")" "a dry run writes no backup"
  pass "dry run: lists only absolute entries whose path is gone, and changes nothing"
}

test_missing_backs_up_then_removes_only_dead_entries() {
  local c before out backup
  c=$(new_store real)
  before=$(cat "$c/config/.claude.json")
  out=$(run_prune "$c/config" --missing)
  assert_contains "$out" "removed: $c/gone" "names the removed entry"
  assert_contains "$out" "claude store: removed 2 of 5 project entries from $c/config/.claude.json; backup $c/config/.claude.json.fm-prune-backup-" \
    "summary names the backup"
  backup=$(find "$c/config" -maxdepth 1 -name '.claude.json.fm-prune-backup-*' | head -n 1)
  assert_equals "$before" "$(cat "$backup")" "the backup holds the store as it was"
  case "${backup##*fm-prune-backup-}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) fail "the backup is dated: $backup" ;;
  esac
  assert_equals "$(printf '%s\n' "$c/dangling" "$c/exists" relative/key)" "$(keys "$c/config/.claude.json")" \
    "only the dead entries are gone"
  node -e 'const j = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    if (j.numStartups !== 7 || j.oauthAccount.emailAddress !== "someone@example.invalid"
      || j.projects[process.argv[2]].hasTrustDialogAccepted !== true) process.exit(1)' \
    "$c/config/.claude.json" "$c/exists" || fail "the rest of the store must stay"
  assert_equals 600 "$(stat -c %a "$c/config/.claude.json" 2>/dev/null || stat -f %Lp "$c/config/.claude.json")" \
    "the store keeps its mode"
  out=$(run_prune "$c/config" --missing)
  assert_equals "claude store: removed 0 of 3 project entries from $c/config/.claude.json" "$out" "a clean store has nothing to remove"
  assert_equals 1 "$(backups "$c/config")" "a run that removes nothing writes no backup"
  pass "--missing: a dated backup first, then only dead entries go and everything else stays"
}

test_path_removes_one_gone_entry_only() {
  local c out
  c=$(new_store one)
  out=$(run_prune "$c/config" --path "$c/exists")
  assert_equals "" "$out" "an existing path is never removed"
  out=$(run_prune "$c/config" --path "$c/gone")
  assert_equals "$(printf 'removed: %s\nclaude store: removed 1 of 5 project entries from %s' "$c/gone" "$c/config/.claude.json")" \
    "$out" "a gone path's entry goes"
  assert_equals "$(printf '%s\n' "$c/dangling" "$c/exists" "$c/gone-too/sub" relative/key)" "$(keys "$c/config/.claude.json")" \
    "--path leaves every other entry, dead ones included"
  out=$(run_prune "$c/config" --path "$c/never-registered")
  assert_equals "" "$out" "a path with no entry prints nothing"
  assert_equals 0 "$(backups "$c/config")" "--path writes no backup"
  pass "--path: removes exactly that entry when its folder is gone, and nothing else"
}

test_store_selection_and_symlinked_store() {
  local c out target
  c=$(new_store home)
  mkdir -p "$c/user-home"
  mv "$c/config/.claude.json" "$c/user-home/.claude.json"
  out=$(env -u CLAUDE_CONFIG_DIR HOME="$c/user-home" bash "$PRUNE" --missing 2>&1)
  assert_contains "$out" "removed 2 of 5 project entries from $c/user-home/.claude.json" "without CLAUDE_CONFIG_DIR the store is HOME's"

  c=$(new_store linked)
  target="$c/dotfiles/claude.json"
  mkdir -p "$c/dotfiles"
  mv "$c/config/.claude.json" "$target"
  ln -s "$target" "$c/config/.claude.json"
  out=$(run_prune "$c/config" --missing)
  assert_contains "$out" "removed 2 of 5 project entries" "a symlinked store is pruned"
  [ -L "$c/config/.claude.json" ] || fail "a symlinked store must stay a symlink"
  assert_equals "$(printf '%s\n' "$c/dangling" "$c/exists" relative/key)" "$(keys "$target")" "the link's target holds the result"

  out=$(run_prune "$TMP_ROOT/empty-config" --missing)
  assert_equals "claude store: removed 0 of 0 project entries from $TMP_ROOT/empty-config/.claude.json" "$out" "a missing store has nothing to remove"
  out=$(run_prune "$TMP_ROOT/empty-config" --path /nonexistent/x)
  assert_equals "" "$out" "--path on a missing store prints nothing"
  pass "store: CLAUDE_CONFIG_DIR else HOME, a symlinked store keeps its link, a missing store is a no-op"
}

test_refusals() {
  local c before code
  c=$(new_store refuse)
  for args in "" "--dry-run" "--missing --path /x" "--path" "--path relative" "--dry-run --path /x" "--bogus"; do
    code=0
    # shellcheck disable=SC2086
    run_prune "$c/config" $args >/dev/null || code=$?
    expect_code 2 "$code" "arguments '$args'"
  done
  code=0
  CLAUDE_CONFIG_DIR=relative/dir bash "$PRUNE" --missing >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a relative CLAUDE_CONFIG_DIR"
  printf '{"projects": ["%s/gone"]}\n' "$c" > "$c/config/.claude.json"
  before=$(cat "$c/config/.claude.json")
  code=0
  run_prune "$c/config" --missing >/dev/null || code=$?
  expect_code 1 "$code" "a non-object projects value"
  assert_equals "$before" "$(cat "$c/config/.claude.json")" "a refused store is unchanged"
  assert_equals 0 "$(backups "$c/config")" "a refused run writes no backup"
  pass "refusals: bad arguments exit 2; a relative CLAUDE_CONFIG_DIR or a malformed store exits 1 unchanged"
}

test_dry_run_lists_dead_entries_and_changes_nothing
test_missing_backs_up_then_removes_only_dead_entries
test_path_removes_one_gone_entry_only
test_store_selection_and_symlinked_store
test_refusals

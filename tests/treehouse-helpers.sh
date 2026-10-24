#!/usr/bin/env bash
# Keep a real-Treehouse test's pools out of the fleet's pool storage.
#
# Treehouse keeps each repository's pool at <root>/.treehouse/<repo>-<hash>,
# where <root> is --root, else TREEHOUSE_ROOT, else the `root` key of
# ~/.config/treehouse/config.toml, else $HOME (verified on treehouse v3.1.5).
# A test that acquires real slots for a temporary repository and only returns
# them leaves its pool in that shared storage, and deleting the repository
# afterwards leaves every slot pointing at a missing git dir. Pointing
# TREEHOUSE_ROOT inside the test's own temporary root instead makes removing
# that root remove the pool with it.
set -u

# treehouse_test_production_storage: print the pool storage Treehouse would use
# for this user with no test isolation, or nothing when the configured root is
# relative (an in-project pool has no single shared storage to watch).
treehouse_test_production_storage() {
  local root=${TREEHOUSE_ROOT:-} config="$HOME/.config/treehouse/config.toml"
  if [ -z "$root" ] && [ -f "$config" ]; then
    # Only a top-level key counts, so stop at the first table header.
    root=$(sed -n -e '/^[[:space:]]*\[/q' \
      -e 's/^[[:space:]]*root[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      -e "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$config" | head -n 1)
  fi
  root=${root:-$HOME}
  case "$root" in
    \~) root=$HOME ;;
    \~/*) root="$HOME/${root#\~/}" ;;
  esac
  case "$root" in
    /*) printf '%s/.treehouse\n' "${root%/}" ;;
  esac
}

# treehouse_test_isolate <test-root>: point every Treehouse call this test and
# its children make at <test-root>/treehouse, remembering the storage they would
# otherwise have used. Call it before provisioning a Herdr lab: a worker pane
# runs `treehouse get` in a shell that inherits the lab server's environment,
# not the spawn's.
treehouse_test_isolate() {
  TREEHOUSE_TEST_PRODUCTION_STORAGE=$(treehouse_test_production_storage)
  TREEHOUSE_TEST_ROOT="$1/treehouse"
  mkdir -p "$TREEHOUSE_TEST_ROOT" || return 1
  export TREEHOUSE_ROOT="$TREEHOUSE_TEST_ROOT"
}

# treehouse_test_require_isolated_worktree <worktree>: succeed only when the
# worktree a spawn acquired lies inside the isolated root; otherwise print why.
treehouse_test_require_isolated_worktree() {
  case "$1" in
    "$TREEHOUSE_TEST_ROOT"/*) return 0 ;;
  esac
  printf 'worktree %s is outside the isolated Treehouse root %s\n' "${1:-<empty>}" "$TREEHOUSE_TEST_ROOT"
  return 1
}

# treehouse_test_production_slots <test-root>: print every slot in production
# pool storage whose git link points into <test-root>, one per line, and fail
# when there is any. This is the leak the isolation exists to prevent: run it
# before the test removes <test-root>, while those links still name it.
treehouse_test_production_slots() {
  local test_root=$1 storage=${TREEHOUSE_TEST_PRODUCTION_STORAGE:-} link found=0
  [ -n "$storage" ] && [ -d "$storage" ] || return 0
  for link in "$storage"/*/*/*/.git; do
    [ -f "$link" ] || continue
    case "$(sed -n 's/^gitdir: //p' "$link")" in
      "$test_root"/*)
        printf '%s\n' "${link%/.git}"
        found=1
        ;;
    esac
  done
  [ "$found" -eq 0 ]
}

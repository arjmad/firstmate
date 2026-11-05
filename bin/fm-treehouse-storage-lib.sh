#!/usr/bin/env bash
# fm-treehouse-storage-lib.sh - resolve the user's shared Treehouse pool
# storage, with no source-time side effects, so a production script and a test
# helper can both load it.
#
# Treehouse keeps each repository's pool at <root>/.treehouse/<repo>-<hash>,
# where <root> is --root, else TREEHOUSE_ROOT, else the `root` key of one
# config file, else $HOME (verified on treehouse v3.1.8). That file is the
# repository's own treehouse.toml when it has one, tracked or not, which
# replaces ~/.config/treehouse/config.toml whole; so a repository file pins
# that one repository's pool, and fm_treehouse_storage answers for every
# repository that carries none.

# fm_treehouse_storage: print the pool storage Treehouse uses for a repository
# with no treehouse.toml of its own, or nothing when that root is relative (an
# in-project pool has no single shared storage to watch).
fm_treehouse_storage() {
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

#!/usr/bin/env bash
# Private local surfaces must be ignored by category, including backup files.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

random_leaf() {
  printf '%s-%s' "$1" "$$-$RANDOM-$RANDOM"
}

test_private_surfaces_ignored_as_categories() {
  local surface sample
  for surface in config data state projects .no-mistakes; do
    for sample in \
      "$surface/$(random_leaf unlisted-key)" \
      "$surface/$(random_leaf nested-dir)/$(random_leaf deep-file)" \
      "$surface/$(random_leaf private).bak" \
      "$surface/$(random_leaf private)~"; do
      git -C "$ROOT" check-ignore -q "$sample" \
        || fail "git does not ignore $sample ($surface/ must be ignored as a directory)"
    done
  done

  for sample in .env .env.bak .env.old .env~ ".env.$(random_leaf editor)"; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (.env backups and variants must remain private)"
  done

  pass "private local surfaces cover unlisted, nested, and backup paths"
}

test_unrelated_paths_stay_visible() {
  local sample
  for sample in "$(random_leaf not-private)" configuration/example dotenv.example; do
    git -C "$ROOT" check-ignore -q "$sample" \
      && fail "git unexpectedly ignores $sample (outside private local surfaces)"
  done
  pass "unrelated paths remain visible to git"
}

test_tracked_files_are_not_ignored() {
  local ignored
  ignored="$(git -C "$ROOT" ls-files | git -C "$ROOT" check-ignore --no-index --stdin || true)"
  [[ -z "$ignored" ]] || fail "a tracked shared file matches .gitignore: $ignored"
  pass "no tracked shared file matches .gitignore"
}

test_private_surfaces_ignored_as_categories
test_unrelated_paths_stay_visible
test_tracked_files_are_not_ignored

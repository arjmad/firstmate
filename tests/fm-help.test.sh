#!/usr/bin/env bash
# tests/fm-help.test.sh - every bin/fm-*.sh entry command answers --help.
#
# The sourced *-lib.sh libraries are not commands and are skipped. Each entry
# command runs once with --help in its own throwaway FM_HOME and HOME, with the
# external tools a command could act through (tmux, herdr, gh, git hosts,
# downloads, model CLIs) replaced by stubs that record any call. A command
# passes only when it exits 0, prints a usage line on stdout, calls none of
# those tools, and leaves its FM_HOME, its HOME and this checkout unchanged.
# A command that still acted on --help would fail here instead of acting.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-help)
STUBS="tmux herdr gh gh-axi curl wget ssh scp rsync claude codex pi opencode
  no-mistakes treehouse lavish-axi chrome-devtools-axi orca aws tasks-axi"

tree_listing() {  # <dir>
  (cd "$1" && find . -print | LC_ALL=C sort)
}

checkout_before=$(git -C "$ROOT" status --porcelain --untracked-files=all)
failures=()
count=0

for script in "$ROOT"/bin/fm-*.sh; do
  case "$script" in *-lib.sh) continue ;; esac
  name=${script##*/}
  count=$((count + 1))
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/user" "$case_dir/fakebin" "$case_dir/cwd"
  for tool in $STUBS; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexit 1\n' "$tool" "$case_dir/calls" \
      > "$case_dir/fakebin/$tool"
    chmod +x "$case_dir/fakebin/$tool"
  done
  home_before=$(tree_listing "$case_dir/home")
  user_before=$(tree_listing "$case_dir/user")

  rc=0
  (
    cd "$case_dir/cwd"
    unset TMUX HERDR_ENV
    export HOME="$case_dir/user" FM_HOME="$case_dir/home" PATH="$case_dir/fakebin:$PATH"
    fm_run_timed 20 bash "$script" --help
  ) </dev/null >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?

  problems=
  [ "$rc" -eq 0 ] || problems="$problems exit=$rc"
  grep -qi 'usage' "$case_dir/stdout" || problems="$problems no-usage-on-stdout"
  [ ! -s "$case_dir/calls" ] || problems="$problems called=$(sort -u "$case_dir/calls" | paste -sd, -)"
  [ "$(tree_listing "$case_dir/home")" = "$home_before" ] || problems="$problems wrote-FM_HOME"
  [ "$(tree_listing "$case_dir/user")" = "$user_before" ] || problems="$problems wrote-HOME"
  [ -z "$problems" ] || failures+=("$name:$problems")
done

[ "$count" -gt 100 ] || fail "expected the full bin/fm-*.sh command set, found only $count"

if [ "${#failures[@]}" -gt 0 ]; then
  printf '  %s\n' "${failures[@]}" >&2
  fail "${#failures[@]} of $count entry commands do not answer --help without acting"
fi
pass "all $count bin/fm-*.sh entry commands print usage on --help and exit 0 without acting"

assert_equals "$checkout_before" "$(git -C "$ROOT" status --porcelain --untracked-files=all)" \
  "--help runs must not change the checkout"
pass "--help runs left the checkout unchanged"

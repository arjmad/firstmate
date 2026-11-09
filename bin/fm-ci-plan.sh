#!/usr/bin/env bash
# fm-ci-plan.sh - decide which CI work a pull request's changes need.
#
# Usage:
#   fm-ci-plan.sh plan --event <name> [--labels <a,b,...>] [--base <git-ref>]
#   fm-ci-plan.sh gate (lint <k>of<n> | lane <lane> | macos) [--only-out <file>]
#   fm-ci-plan.sh explain
#
# plan prints one JSON plan on stdout and exits 0 whenever it can read the
# repository; it never decides which shard runs, only what the change touches:
#   {"version":1,"head":"<sha>","mode":"affected"|"full","reasons":[...],
#    "changed":[...],"tests":[...],"lint_roots":[...]}
# tests is the behavior scripts `bin/fm-test-run.sh --list --changed` selects,
# and lint_roots is every canonical ShellCheck root (`bin/fm-lint.sh
# --list-files` in CI) whose analysis can see a changed file: the changed roots
# themselves plus, to a fixpoint, every root whose `source`/`.` line or
# `# shellcheck source=` directive names the basename of a changed path or of a
# root already selected. A deleted file still seeds by name, so the roots that
# still source it are linted and ShellCheck reports the dangling source.
# Changed paths come from `git diff --name-only --no-renames <base>...HEAD`, so a
# rename lists both sides; uncommitted work is not read, so run it on a clean
# tree.
#
# Full mode empties tests and lint_roots and means "run everything".
# plan chooses full, giving every reason that applies, when:
#   - the event is not pull_request (push, workflow_dispatch, anything else);
#   - the labels include full-ci;
#   - more than FM_CI_PLAN_MAX_FILES (default 25) paths changed;
#   - a path under bin/ or tests/ was deleted, because the runner maps a
#     deleted script to nothing and its remaining consumers could go unselected;
#   - a path matches full_trigger (below): CI configuration, shared libraries,
#     and the toolchain that selects, lints, or installs for CI;
#   - a changed path is sourced broadly: more than FM_CI_PLAN_BROAD_SOURCERS
#     (default 8) distinct canonical files name its basename on a source line
#     or directive;
#   - `bin/fm-test-run.sh --list --changed` fails, which is how it refuses a
#     path its map does not cover;
#   - anything else fails: an unreadable base, a failed listing, a jq error.
#     The reason then starts with "error:".
#
# gate reads the plan from $FM_CI_PLAN and prints run=true or run=false, plus
# only=<file> for a lane that runs a subset; it appends the same lines to
# $GITHUB_OUTPUT when that is set. Each check intersects the plan's sets with
# its own membership from the owning script, using its own k-of-n, so the plan
# never records a shard count that a workflow matrix could disagree with:
#   lint <k>of<n>  runs when full, or when `bin/fm-lint.sh --partition <k>of<n>
#                  --list-files` shares a root with lint_roots; a partition
#                  that runs, runs whole;
#   lane <lane>    runs whole when full; otherwise runs only the members of
#                  `bin/fm-test-run.sh --list --lane <lane>` that are in tests,
#                  written one per line to --only-out for the lane's --only,
#                  and is a no-op when there are none;
#   macos          runs when full, or when lint_roots or tests is non-empty.
# gate exits 2, so the check turns red rather than silently no-op, when the
# plan is missing or malformed, when it was planned for another commit than
# HEAD, or when the owner refuses the shard.
#
# explain renders $FM_CI_PLAN as Markdown for a job summary.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_FILES=${FM_CI_PLAN_MAX_FILES:-25}
BROAD_SOURCERS=${FM_CI_PLAN_BROAD_SOURCERS:-8}
FULL_CI_LABEL=full-ci

die() {
  printf 'fm-ci-plan: %s\n' "$*" >&2
  exit 2
}

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# A case pattern's * spans /, so bin/*-lib.sh also covers bin/backends/*-lib.sh.
full_trigger() {
  case "$1" in
    .github/*|.shellcheckrc|\
    bin/*-lib.sh|\
    tests/lib.sh|tests/fixtures.sh|tests/git-config-helpers.sh|\
    bin/fm-ci-plan.sh|bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh|\
    bin/fm-lint.sh|bin/fm-lint-workflows.sh|bin/fm-install-*.sh|\
    bin/fm-herdr-ci-cleanup.sh)
      return 0
      ;;
  esac
  return 1
}

lines_to_json() {
  jq -R . | jq -s -c 'map(select(length > 0))'
}

source_edges() {
  local canonical=$1 f tok
  while IFS= read -r f; do
    [ -f "$ROOT/$f" ] || continue
    {
      grep -vE '^[[:space:]]*#' "$ROOT/$f" \
        | grep -oE '(^|[[:space:];&|{(!])(\.|source)[[:space:]]+[^;&|#]*' || true
      grep -oE '#[[:space:]]*shellcheck[[:space:]]+source=[^[:space:]]+' "$ROOT/$f" || true
    } | grep -oE '[A-Za-z0-9_.-]+\.(sh|bash)' | LC_ALL=C sort -u \
      | while IFS= read -r tok; do printf '%s\t%s\n' "$f" "$tok"; done
  done <"$canonical"
}

lint_closure() {
  local canonical=$1 edges=$2 changed=$3 work
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-plan-lint.XXXXXX") || return 1
  grep -Fxf "$canonical" "$changed" | LC_ALL=C sort -u >"$work/roots" || true
  while IFS= read -r p; do basename "$p"; done <"$changed" | LC_ALL=C sort -u >"$work/names"
  while :; do
    awk -F'\t' 'NR == FNR { want[$0] = 1; next } ($2 in want) { print $1 }' \
      "$work/names" "$edges" | LC_ALL=C sort -u >"$work/hits"
    cat "$work/roots" "$work/hits" | LC_ALL=C sort -u >"$work/next"
    if cmp -s "$work/next" "$work/roots"; then
      break
    fi
    mv "$work/next" "$work/roots"
    while IFS= read -r p; do basename "$p"; done <"$work/roots" \
      | cat - "$work/names" | LC_ALL=C sort -u >"$work/names.next"
    mv "$work/names.next" "$work/names"
  done
  LC_ALL=C sort -u "$work/roots"
  rm -rf "$work"
}

emit_plan() {
  local head=$1 mode=$2 reasons=$3 changed=$4 tests=$5 roots=$6
  jq -n -c --arg head "$head" --arg mode "$mode" \
    --argjson reasons "$(lines_to_json <"$reasons")" \
    --argjson changed "$(lines_to_json <"$changed")" \
    --argjson tests "$(lines_to_json <"$tests")" \
    --argjson roots "$(lines_to_json <"$roots")" \
    '{version: 1, head: $head, mode: $mode, reasons: $reasons,
      changed: $changed, tests: $tests, lint_roots: $roots}'
}

compute_plan() {
  local work=$1 event=$2 labels=$3 base=$4 count p n err
  : >"$work/reasons"
  : >"$work/changed"
  : >"$work/tests"
  : >"$work/roots"
  if [ "$event" != pull_request ]; then
    printf 'event %s runs the full suite\n' "$event" >>"$work/reasons"
  fi
  if printf '%s\n' "$labels" | tr ',' '\n' | grep -Fxq "$FULL_CI_LABEL"; then
    printf 'label %s\n' "$FULL_CI_LABEL" >>"$work/reasons"
  fi
  [ ! -s "$work/reasons" ] || return 0

  [ -n "$base" ] || { echo "error: pull_request planning needs --base" >"$work/error"; return 1; }
  git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || { echo "error: base ref not found: $base" >"$work/error"; return 1; }
  git -C "$ROOT" diff --name-only --no-renames "$base...HEAD" >"$work/changed.raw" 2>"$work/err" \
    || { echo "error: git diff failed: $(tail -1 "$work/err")" >"$work/error"; return 1; }
  LC_ALL=C sort -u "$work/changed.raw" >"$work/changed"

  count=$(grep -c . "$work/changed" || true)
  if [ "$count" -gt "$MAX_FILES" ]; then
    printf '%s changed files is more than %s\n' "$count" "$MAX_FILES" >>"$work/reasons"
  fi
  git -C "$ROOT" diff --name-only --no-renames --diff-filter=D "$base...HEAD" >"$work/deleted" 2>/dev/null \
    || { echo "error: git diff of deletions failed" >"$work/error"; return 1; }
  while IFS= read -r p; do
    case "$p" in
      bin/*|tests/*) printf 'deleted %s\n' "$p" >>"$work/reasons" ;;
    esac
  done <"$work/deleted"
  while IFS= read -r p; do
    if full_trigger "$p"; then
      printf 'full-suite path %s\n' "$p" >>"$work/reasons"
    fi
  done <"$work/changed"
  [ ! -s "$work/reasons" ] || return 0

  CI=true "$ROOT/bin/fm-lint.sh" --list-files >"$work/canonical" 2>"$work/err" \
    || { echo "error: lint inventory failed: $(tail -1 "$work/err")" >"$work/error"; return 1; }
  source_edges "$work/canonical" >"$work/edges" \
    || { echo "error: could not read source edges" >"$work/error"; return 1; }
  while IFS= read -r p; do
    n=$(awk -F'\t' -v want="$(basename "$p")" '$2 == want { print $1 }' "$work/edges" | LC_ALL=C sort -u | grep -c . || true)
    if [ "$n" -gt "$BROAD_SOURCERS" ]; then
      printf 'broadly sourced %s (%s files source it)\n' "$p" "$n" >>"$work/reasons"
    fi
  done <"$work/changed"
  [ ! -s "$work/reasons" ] || return 0

  if ! "$ROOT/bin/fm-test-run.sh" --list --changed --base "$base" >"$work/tests" 2>"$work/err"; then
    err=$(grep -v '^$' "$work/err" | tail -1)
    printf 'changed-test selection refused: %s\n' "${err#fm-test-run: }" >>"$work/reasons"
    : >"$work/tests"
    return 0
  fi
  lint_closure "$work/canonical" "$work/edges" "$work/changed" >"$work/roots" \
    || { echo "error: lint closure failed" >"$work/error"; return 1; }
}

cmd_plan() {
  local event='' labels='' base='' work head mode
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event) [ "$#" -gt 1 ] || die "--event requires a name"; event=$2; shift 2 ;;
      --labels) [ "$#" -gt 1 ] || die "--labels requires a comma-separated list"; labels=$2; shift 2 ;;
      --base) [ "$#" -gt 1 ] || die "--base requires a git ref"; base=$2; shift 2 ;;
      *) die "plan: unknown argument: $1" ;;
    esac
  done
  [ -n "$event" ] || die "plan requires --event"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || die "cannot read HEAD in $ROOT"
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-plan.XXXXXX") || die "cannot create a scratch directory"
  if ! compute_plan "$work" "$event" "$labels" "$base"; then
    cat "$work/error" >"$work/reasons" 2>/dev/null || echo "error: planning failed" >"$work/reasons"
  fi
  if [ -s "$work/reasons" ]; then
    mode=full
    : >"$work/tests"
    : >"$work/roots"
  else
    mode=affected
  fi
  emit_plan "$head" "$mode" "$work/reasons" "$work/changed" "$work/tests" "$work/roots" \
    || { rm -rf "$work"; die "could not encode the plan"; }
  rm -rf "$work"
}

read_plan() {
  local head
  [ -n "${FM_CI_PLAN:-}" ] || die "FM_CI_PLAN is empty: the plan job produced no plan"
  printf '%s' "$FM_CI_PLAN" | jq -e '
    .version == 1 and (.head | type == "string") and
    (.mode == "full" or .mode == "affected") and
    (.tests | type == "array") and (.lint_roots | type == "array")' >/dev/null 2>&1 \
    || die "FM_CI_PLAN is not a version 1 plan"
  head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || die "cannot read HEAD in $ROOT"
  [ "$(printf '%s' "$FM_CI_PLAN" | jq -r .head)" = "$head" ] \
    || die "FM_CI_PLAN was planned for $(printf '%s' "$FM_CI_PLAN" | jq -r .head), not HEAD $head"
}

plan_field() {
  printf '%s' "$FM_CI_PLAN" | jq -r ".$1[]"
}

gate_print() {
  local line
  for line in "$@"; do
    printf '%s\n' "$line"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      printf '%s\n' "$line" >>"$GITHUB_OUTPUT"
    fi
  done
}

cmd_gate() {
  local kind=${1:-} arg='' only_out='' mode members selected
  [ -n "$kind" ] || die "gate requires lint <k>of<n>, lane <lane>, or macos"
  shift
  case "$kind" in
    lint|lane) [ "$#" -gt 0 ] || die "gate $kind requires an argument"; arg=$1; shift ;;
    macos) ;;
    *) die "gate: unknown check $kind" ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --only-out) [ "$#" -gt 1 ] || die "--only-out requires a file"; only_out=$2; shift 2 ;;
      *) die "gate: unknown argument: $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq is required"
  read_plan
  mode=$(printf '%s' "$FM_CI_PLAN" | jq -r .mode)

  case "$kind" in
    lint)
      members=$("$ROOT/bin/fm-lint.sh" --partition "$arg" --list-files) \
        || die "bin/fm-lint.sh refused partition $arg"
      if [ "$mode" = full ] || grep -Fxq -f <(plan_field lint_roots) <<<"$members"; then
        gate_print run=true
      else
        gate_print run=false
      fi
      ;;
    lane)
      members=$("$ROOT/bin/fm-test-run.sh" --list --lane "$arg") \
        || die "bin/fm-test-run.sh refused lane $arg"
      if [ "$mode" = full ]; then
        gate_print run=true
        return 0
      fi
      selected=$(grep -Fx -f <(plan_field tests) <<<"$members" || true)
      if [ -z "$selected" ]; then
        gate_print run=false
        return 0
      fi
      if [ -n "$only_out" ]; then
        printf '%s\n' "$selected" >"$only_out" || die "cannot write $only_out"
        gate_print run=true "only=$only_out"
      else
        gate_print run=true
        printf '%s\n' "$selected"
      fi
      ;;
    macos)
      if [ "$mode" = full ] || [ -n "$(plan_field lint_roots)$(plan_field tests)" ]; then
        gate_print run=true
      else
        gate_print run=false
      fi
      ;;
  esac
}

cmd_explain() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  [ -n "${FM_CI_PLAN:-}" ] || die "FM_CI_PLAN is empty"
  printf '%s' "$FM_CI_PLAN" | jq -r '
    "## CI plan: \(.mode)",
    "",
    (if .mode == "full" then (.reasons | map("- " + .) | .[]) else
      "\(.tests | length) behavior scripts and \(.lint_roots | length) lint roots are affected." end),
    "",
    "Changed files (\(.changed | length)):",
    "",
    (.changed | map("- `" + . + "`") | .[])'
}

case "${1:-}" in
  plan) shift; cmd_plan "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  explain) shift; cmd_explain ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

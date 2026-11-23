#!/usr/bin/env bash
# fm-agents-md-budget.sh - fail when AGENTS.md nears Codex's project-doc byte budget.
# Usage:
#   fm-agents-md-budget.sh [--file <path> | --repo <dir>] [--budget <bytes>] [--margin <bytes>]
#
# Codex reads at most project_doc_max_bytes of project instructions and silently
# truncates the rest, so a Codex primary, secondmate, or worker in this repo would
# lose the tail of the contract with no error. The default budget is Codex's
# DEFAULT_PROJECT_DOC_MAX_BYTES (32 * 1024 = 32768, codex-rs/config/src/config_toml.rs).
# The check passes only while the file stays at or under budget minus margin
# (default margin 2048 bytes), so growth is caught before it reaches the cut.
# The budget is shared by every AGENTS.md from the repository root down to the
# working folder, so by default the check sums the root AGENTS.md and every nested
# AGENTS.md git tracks in --repo (default this repository; ignored paths such as
# projects/ are excluded). --file measures one file instead; sizes are in bytes.
# Prints one "ok" line on success; prints the overrun to stderr and exits 1 otherwise.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE=
REPO=$ROOT
BUDGET=32768
MARGIN=2048

usage() {
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-agents-md-budget: %s\n' "$1" >&2
  exit "${2:-1}"
}

is_count() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file|--repo|--budget|--margin)
      [ "$#" -ge 2 ] || die "$1 needs a value" 2
      case "$1" in
        --file) FILE=$2 ;;
        --repo) REPO=$2 ;;
        --budget) BUDGET=$2 ;;
        --margin) MARGIN=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

is_count "$BUDGET" || die "--budget must be a whole number of bytes: $BUDGET" 2
is_count "$MARGIN" || die "--margin must be a whole number of bytes: $MARGIN" 2
[ "$MARGIN" -lt "$BUDGET" ] || die "--margin $MARGIN must be smaller than --budget $BUDGET" 2
if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || die "not a readable file: $FILE" 2
  bytes=$(wc -c < "$FILE" | tr -d ' ')
  label=$FILE
else
  [ -f "$REPO/AGENTS.md" ] || die "no root AGENTS.md in $REPO" 2
  tracked=$(git -C "$REPO" ls-files -- AGENTS.md '*/AGENTS.md') \
    || die "cannot list tracked AGENTS.md files in $REPO" 2
  bytes=0
  count=0
  while IFS= read -r rel; do
    [ -n "$rel" ] && [ -f "$REPO/$rel" ] || continue
    bytes=$((bytes + $(wc -c < "$REPO/$rel" | tr -d ' ')))
    count=$((count + 1))
  done <<EOF_TRACKED
$tracked
EOF_TRACKED
  label="the AGENTS.md chain ($count tracked files under $REPO)"
fi
limit=$((BUDGET - MARGIN))
if [ "$bytes" -gt "$limit" ]; then
  die "$label is $bytes bytes, $((bytes - limit)) over the $limit-byte limit (Codex budget $BUDGET minus margin $MARGIN); prune it as AGENTS.md \"Maintaining this file\" says, moving conditional detail to its owning skill or doc behind a pointer; do not raise the limit"
fi
printf 'fm-agents-md-budget: ok bytes=%s limit=%s budget=%s margin=%s headroom=%s\n' \
  "$bytes" "$limit" "$BUDGET" "$MARGIN" "$((limit - bytes))"

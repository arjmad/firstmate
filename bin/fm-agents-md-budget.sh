#!/usr/bin/env bash
# fm-agents-md-budget.sh - fail when AGENTS.md nears Codex's project-doc byte budget.
# Usage:
#   fm-agents-md-budget.sh [--file <path>] [--budget <bytes>] [--margin <bytes>]
#
# Codex reads at most project_doc_max_bytes of project instructions and silently
# truncates the rest, so a Codex primary, secondmate, or worker in this repo would
# lose the tail of the contract with no error. The default budget is Codex's
# DEFAULT_PROJECT_DOC_MAX_BYTES (32 * 1024 = 32768, codex-rs/config/src/config_toml.rs).
# The check passes only while the file stays at or under budget minus margin
# (default margin 2048 bytes), so growth is caught before it reaches the cut.
# --file defaults to this repository's AGENTS.md; sizes are counted in bytes.
# Prints one "ok" line on success; prints the overrun to stderr and exits 1 otherwise.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/AGENTS.md"
BUDGET=32768
MARGIN=2048

usage() {
  sed -n '2,13{s/^# \{0,1\}//;p;}' "$0"
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
    --file|--budget|--margin)
      [ "$#" -ge 2 ] || die "$1 needs a value" 2
      case "$1" in
        --file) FILE=$2 ;;
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
[ -f "$FILE" ] || die "not a readable file: $FILE" 2

bytes=$(wc -c < "$FILE" | tr -d ' ')
limit=$((BUDGET - MARGIN))
if [ "$bytes" -gt "$limit" ]; then
  die "$FILE is $bytes bytes, $((bytes - limit)) over the $limit-byte limit (Codex budget $BUDGET minus margin $MARGIN); move conditional detail to its owning skill or doc behind a pointer"
fi
printf 'fm-agents-md-budget: ok bytes=%s limit=%s budget=%s margin=%s headroom=%s\n' \
  "$bytes" "$limit" "$BUDGET" "$MARGIN" "$((limit - bytes))"

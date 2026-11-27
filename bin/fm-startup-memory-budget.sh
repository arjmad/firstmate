#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   fm-startup-memory-budget.sh read
#   fm-startup-memory-budget.sh report
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/captain.md, data/captain-shared.md, and data/learnings.md together, then
# the whole session-start digest as this home last printed it: the newest
# saved copy under state/.digest-read/ measured in bytes against the hook
# output cap bin/fm-digest-read-check.sh enforces, with the forced-read chunk
# count when it spills (digest_status=inline|spills, or unmeasured with
# digest_copy=none when no Claude session start saved one).  The digest lines
# are a measurement, not a verdict: budget_status covers the three files only.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'startup-memory-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# report_digest: the newest saved session-start digest against the limits
# bin/fm-digest-read-check.sh owns.  Absence is a normal state (another
# harness, or no session start since the two-day prune), never an error.
report_digest() {
  local dir="$STATE/.digest-read" f m newest='' newest_m=-1 limits line
  local cap='' chunk='' bytes lines age chunks status
  for f in "$dir"/*.txt; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    m=$(file_mtime "$f") || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ "$m" -gt "$newest_m" ]; then
      newest=$f
      newest_m=$m
    fi
  done
  if [ -z "$newest" ]; then
    printf 'digest_copy=none
'
    printf 'digest_status=unmeasured
'
    return 0
  fi
  limits=$("$SCRIPT_DIR/fm-digest-read-check.sh" limits 2>/dev/null) || limits=''
  while IFS= read -r line; do
    case "$line" in
      spill_threshold_bytes=*) cap=${line#*=} ;;
      read_chunk_lines=*) chunk=${line#*=} ;;
    esac
  done <<EOF_LIMITS
$limits
EOF_LIMITS
  bytes=$(LC_ALL=C wc -c < "$newest" 2>/dev/null | tr -d '[:space:]')
  # A copy pruned or made unreadable since it was picked is unmeasured, not a
  # failed report: set -e would otherwise end the report here.
  lines=$(awk 'END { print NR }' "$newest" 2>/dev/null) || lines=''
  case "$cap:$chunk:$bytes:$lines" in
    *[!0-9:]*|:*|*::*|*:)
      printf 'digest_copy=%s
' "${newest#"$FM_HOME"/}"
      printf 'digest_status=unmeasured
'
      return 0
      ;;
  esac
  age=$(( $(date +%s) - newest_m ))
  [ "$age" -ge 0 ] || age=0
  if [ "$bytes" -gt "$cap" ]; then
    status=spills
    chunks=$(( (lines + chunk - 1) / chunk ))
  else
    status=inline
    chunks=0
  fi
  printf 'digest_copy=%s
' "${newest#"$FM_HOME"/}"
  printf 'digest_copy_age_seconds=%s
' "$age"
  printf 'digest_bytes=%s
' "$bytes"
  printf 'digest_estimated_tokens=%s
' "$(( (bytes + 2) / 3 ))"
  printf 'digest_lines=%s
' "$lines"
  printf 'digest_inline_cap_bytes=%s
' "$cap"
  printf 'digest_status=%s
' "$status"
  printf 'digest_forced_read_chunks=%s
' "$chunks"
}

report() {
  local budget bytes tokens presence total=0 shared_tokens=0 role=primary
  if ! budget=$(read_budget); then
    return 2
  fi

  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    role=secondmate
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in captain.md captain-shared.md learnings.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    presence=$FM_STARTUP_MEMORY_MEASURE_PRESENCE
    total=$((total + tokens))
    [ "$file" != captain-shared.md ] || shared_tokens=$tokens
    printf 'file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$bytes" "$tokens" "$presence"
  done
  printf 'total_estimated_tokens=%s\n' "$total"
  if fm_startup_memory_decimal_le "$total" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
  if [ "$role" = secondmate ] \
    && ! fm_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi
  report_digest
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# fm-intake-spill.sh - whether this home is too busy to run more work itself,
# and which secondmate takes the work that does not need this home.
#
# At every ship or scout intake, firstmate places the task: in this home, or
# with the registered secondmate whose scope fits it (docs/task-lifecycle.md
# "Intake and authority" owns that rule). Scope alone keeps work home while the
# home's machine is overloaded or its worker slots are full, so a home can
# declare a spill: past a load or worker threshold, work that needs nothing only
# this home can reach goes to a named secondmate even outside its scope. This
# script measures the home against that declaration and prints the verdict;
# firstmate still judges which work needs this home, and records where the task
# runs and why in its backlog note. It changes nothing and never spawns.
#
# Usage: fm-intake-spill.sh
#
# Declaration: config/intake-spill in this home (FM_CONFIG_OVERRIDE selects the
# config directory). It is home-local and not inherited by secondmate homes,
# which do not spawn secondmates. One `<key> <value>` pair per line; blank lines
# and lines starting with `#` are ignored:
#   to <secondmate-id>   required; a secondmate registered in data/secondmates.md
#   load <number>        spill while this machine's 5-minute load average is
#                        above <number>
#   workers <count>      spill while this home holds at least <count> worker
#                        records (fm-afk-contract.sh live-workers: every
#                        state/*.meta that is not a secondmate)
#   short <minutes>      work expected to take under <minutes> stays in this
#                        home even when a secondmate scope fits, because a
#                        handoff costs more than it saves; printed for
#                        firstmate's judgment, never measured
# At least one of load and workers is required. A key named twice, an unknown
# key, a malformed value, or a `to` id the registry does not hold makes the
# declaration unreadable.
#
# Output, one `key: value` line each, in this order:
#   spill: yes | no | off     off: no declaration, so placement is scope alone
#   reason: <one line>        what decided the verdict, for the backlog note
#   to: <secondmate-id>       absent when off
#   load: <value> (above <n> spills) | <value> (not declared) | unknown (...)
#   workers: <count> (at <n> spills) | <count> (not declared)
#   short: <minutes> | none   absent when off
# A load this script cannot measure is printed as unknown and never spills by
# itself; the worker threshold still applies.
#
# Exit: 0 with a verdict, including off. 2 for a usage error or an unreadable
# declaration, which is actionable and never silently treated as off.
#
# Environment:
#   FM_INTAKE_SPILL_LOADAVG  use this value as the 5-minute load average instead
#                            of measuring it (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() {
  printf 'fm-intake-spill: %s\n' "$1" >&2
  exit 2
}

case "${1:-}" in
  -h | --help)
    sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac
[ "$#" -eq 0 ] || die "takes no arguments (see --help)"

decl="$CONFIG/intake-spill"
if [ ! -e "$decl" ] && [ ! -L "$decl" ]; then
  printf 'spill: off\nreason: no config/intake-spill declaration, so placement follows secondmate scope alone\n'
  exit 0
fi
[ -f "$decl" ] && [ -r "$decl" ] || die "$decl is not a readable file"

to='' load_max='' workers_max='' short=''
seen='|'
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  case "$line" in '' | '#'*) continue ;; esac
  read -r key value extra <<<"$line"
  [ -n "${key:-}" ] || continue
  [ -n "${value:-}" ] && [ -z "${extra:-}" ] || die "$decl line $lineno: expected '<key> <value>'"
  case "$seen" in *"|$key|"*) die "$decl line $lineno: '$key' is declared twice" ;; esac
  seen="$seen$key|"
  case "$key" in
    to)
      case "$value" in *[!A-Za-z0-9._-]*) die "$decl line $lineno: '$value' is not a secondmate id" ;; esac
      to=$value
      ;;
    load)
      [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$decl line $lineno: load '$value' is not a non-negative number"
      load_max=$value
      ;;
    workers)
      [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || die "$decl line $lineno: workers '$value' is not a positive integer"
      workers_max=$value
      ;;
    short)
      [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || die "$decl line $lineno: short '$value' is not a positive number of minutes"
      short=$value
      ;;
    *) die "$decl line $lineno: unknown key '$key'" ;;
  esac
done <"$decl"

[ -n "$to" ] || die "$decl names no 'to <secondmate-id>'"
[ -n "$load_max" ] || [ -n "$workers_max" ] || die "$decl declares neither 'load' nor 'workers'"
secondmate_registry_line_for_id "$DATA/secondmates.md" "$to" \
  || die "spill target '$to' is not one registered secondmate in $DATA/secondmates.md"

# The 5-minute load average: steadier than the 1-minute figure, so one short
# build does not move a placement.
measure_load() {
  local avg
  if [ -n "${FM_INTAKE_SPILL_LOADAVG:-}" ]; then
    printf '%s\n' "$FM_INTAKE_SPILL_LOADAVG"
    return 0
  fi
  if [ -r /proc/loadavg ]; then
    read -r _ avg _ </proc/loadavg && printf '%s\n' "$avg" && return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    # macOS: "{ 1.23 1.45 1.67 }"
    avg=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $2}')
    [ -n "$avg" ] && printf '%s\n' "$avg" && return 0
  fi
  return 1
}

load=$(measure_load) || load=
[[ "$load" =~ ^[0-9]+([.][0-9]+)?$ ]] || load=
workers=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" live-workers 2>/dev/null) || workers=
[[ "$workers" =~ ^[0-9]+$ ]] || die "cannot count this home's worker records in $STATE"

spill=no
reason=
if [ -n "$load_max" ] && [ -n "$load" ] && awk -v l="$load" -v m="$load_max" 'BEGIN { exit !(l > m) }'; then
  spill=yes
  reason="5-minute load $load is above $load_max"
fi
if [ -n "$workers_max" ] && [ "$workers" -ge "$workers_max" ]; then
  spill=yes
  reason="${reason:+$reason; }$workers worker records reach the $workers_max-worker threshold"
fi
if [ "$spill" = no ]; then
  reason="below every declared threshold"
  [ -z "$load_max" ] || [ -n "$load" ] || reason="load could not be measured and the worker count is below its threshold"
  [ -n "$workers_max" ] || [ -n "$load" ] || reason="load could not be measured, so no threshold applies"
fi

printf 'spill: %s\nreason: %s\nto: %s\n' "$spill" "$reason" "$to"
if [ -z "$load" ]; then
  printf 'load: unknown (cannot read this machine'\''s load average)\n'
elif [ -n "$load_max" ]; then
  printf 'load: %s (above %s spills)\n' "$load" "$load_max"
else
  printf 'load: %s (not declared)\n' "$load"
fi
if [ -n "$workers_max" ]; then
  printf 'workers: %s (at %s spills)\n' "$workers" "$workers_max"
else
  printf 'workers: %s (not declared)\n' "$workers"
fi
printf 'short: %s\n' "${short:-none}"

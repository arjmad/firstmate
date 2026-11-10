#!/usr/bin/env bash
# fm-intake-spill.sh - whether this home is too busy to run more work itself,
# which secondmate takes the work that does not need this home, and whether a
# project's placement rule sends its work to a remote secondmate first.
#
# At every ship or scout intake, firstmate places the task: in this home, or
# with the registered secondmate whose scope fits it (docs/task-lifecycle.md
# "Intake and authority" owns that rule). Scope alone keeps work home while the
# home's machine is overloaded or its worker slots are full, so a home can
# declare a spill: past a load or worker threshold, work that needs nothing only
# this home can reach goes to a named secondmate even outside its scope. This
# script measures the home against that declaration and prints the verdict;
# firstmate still judges which work needs this home, and records where the task
# runs and why in its backlog note. It never spawns.
#
# A home can also declare a first rule: fresh ships and scouts for the named
# projects go to one remote secondmate first, and fall back to this home only
# when that secondmate does not answer, is not running, or has no free slot
# under its memory ceiling. --project <name> judges that rule for one project;
# bin/fm-spawn.sh runs it before a fresh ship or scout and refuses a local
# spawn the rule sends elsewhere.
#
# Usage: fm-intake-spill.sh [--project <name>]
#
# Declaration: config/intake-spill in this home (FM_CONFIG_OVERRIDE selects the
# config directory). It is home-local and not inherited by secondmate homes,
# which do not spawn secondmates. One `<key> <value>` pair per line; blank lines
# and lines whose first word starts with `#` are ignored:
#   to <secondmate-id>   a secondmate registered in data/secondmates.md; required
#                        with load or workers
#   load <number>        spill while this machine's 5-minute load average is
#                        above <number>; needs a remote `to`, because a local
#                        secondmate shares this machine's load
#   workers <count>      spill while this home holds at least <count> worker
#                        records (fm-afk-contract.sh live-workers: every
#                        state/*.meta that is not a secondmate)
#   short <minutes>      work expected to take under <minutes> stays in this
#                        home even when a secondmate scope fits, because a
#                        handoff costs more than it saves; printed for
#                        firstmate's judgment, never measured
#   first <secondmate-id> <project>...
#                        the projects (clone names under projects/) whose fresh
#                        ships and scouts go to this remote secondmate first
# A spill is `to` with at least one of load and workers; a declaration holds a
# spill, a first rule, or both. A key named twice, an unknown key, a malformed
# value, a `to` or `first` id the registry does not hold, or a local `first`
# secondmate makes the declaration unreadable.
#
# Output, one `key: value` line each, in this order:
#   spill: yes | no | off     off: no spill declared, so placement is scope alone
#   reason: <one line>        what decided the verdict, for the backlog note
#   to: <secondmate-id>       absent when off
#   load: <value> (above <n> spills) | <value> (not declared) | unknown (...)
#   workers: <count> (at <n> spills) | <count> (not declared)
#   short: <minutes> | none   absent when off, except a short declared beside
#                             a first rule alone
# With --project, three more lines follow (first-notice only on a fallback):
#   first: <secondmate-id> | fallback | none
#   first-reason: <one line>  for the backlog note and the task record
#   first-notice: tell the captain | already told
# A load this script cannot measure is printed as unknown and never spills by
# itself; the worker threshold still applies.
#
# The first-rule probe makes two bounded calls through bin/fm-on.sh, each
# limited to FM_INTAKE_FIRST_TIMEOUT seconds (default 20):
#   fm-remote-secondmate-control.sh state <id>   the endpoint must be alive
#   fm-capacity.sh --json                        the remote home's lane facts
# An SSH failure or timeout means the secondmate does not answer. Free slots
# count memory and the lane ceiling only: in auto mode the smaller of the
# budget's memory and ceiling figures, and none while its memory-pressure or
# swap gate is closed; with a fixed cap the cap minus its lanes, and none while
# a memory constraint holds or its published available memory leaves under
# 1 GB above min-avail-gb (else the larger of 10% of RAM and 2 GB). CPU load, GPU use, a reserve flag, and captain
# presence never count, so a machine its owner is gaming on stays available.
# A remote home without config/lane-capacity has no measured slots, and the
# rule falls back with that reason. The first fallback in this home prints
# `first-notice: tell the captain` and creates state/.intake-first-told; every
# later fallback prints `already told`. Removing that file re-arms the notice.
#
# Exit: 0 with a verdict, including off and a fallback. 2 for a usage error or
# an unreadable declaration, which is actionable and never silently treated as
# off.
#
# Environment:
#   FM_INTAKE_SPILL_LOADAVG  use this value as the 5-minute load average instead
#                            of measuring it (tests)
#   FM_INTAKE_FIRST_TIMEOUT  seconds each first-rule remote call may take
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

project=
case "${1:-}" in
  -h | --help)
    sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  --project)
    [ "$#" -eq 2 ] || die "--project takes one project name (see --help)"
    project=$2
    case "$project" in '' | -* | *[!A-Za-z0-9._-]*) die "project name '$project' is not a clone name" ;; esac
    shift 2
    ;;
esac
[ "$#" -eq 0 ] || die "takes no arguments other than --project <name> (see --help)"

# first_none <reason>: the --project lines when no first rule covers it.
first_none() {
  [ -n "$project" ] || return 0
  printf 'first: none\nfirst-reason: %s\n' "$1"
}

decl="$CONFIG/intake-spill"
if [ ! -e "$decl" ] && [ ! -L "$decl" ]; then
  printf 'spill: off\nreason: no config/intake-spill declaration, so placement follows secondmate scope alone\n'
  first_none "no config/intake-spill declaration, so $project has no first rule"
  exit 0
fi
[ -f "$decl" ] && [ -r "$decl" ] || die "$decl is not a readable file"

to='' load_max='' workers_max='' short='' first_id='' first_projects='' first_host=''
seen='|'
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  read -r key value extra <<<"$line"
  case "${key:-}" in '' | '#'*) continue ;; esac
  case "$seen" in *"|$key|"*) die "$decl line $lineno: '$key' is declared twice" ;; esac
  seen="$seen$key|"
  if [ "$key" = first ]; then
    [ -n "${value:-}" ] && [ -n "${extra:-}" ] || die "$decl line $lineno: expected 'first <secondmate-id> <project>...'"
    first_id=$value
    read -r -a first_list <<<"$extra"
    for p in "${first_list[@]}"; do
      case "$p" in -* | *[!A-Za-z0-9._-]*) die "$decl line $lineno: project '$p' is not a clone name" ;; esac
    done
    first_projects=" ${first_list[*]} "
    continue
  fi
  [ -n "${value:-}" ] && [ -z "${extra:-}" ] || die "$decl line $lineno: expected '<key> <value>'"
  case "$key" in
    to)
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

if [ -n "$first_id" ]; then
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$first_id" \
    || die "first-rule secondmate '$first_id' is not one registered secondmate in $DATA/secondmates.md"
  [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] \
    || die "'first' needs a remote secondmate; '$first_id' runs on this machine"
  first_host=$SECONDMATE_REGISTRY_HOST
fi
spill_declared=0
if [ -n "$to" ] || [ -n "$load_max" ] || [ -n "$workers_max" ] || [ -z "$first_id" ]; then
  spill_declared=1
  [ -n "$to" ] || die "$decl names no 'to <secondmate-id>'"
  [ -n "$load_max" ] || [ -n "$workers_max" ] || die "$decl declares neither 'load' nor 'workers'"
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$to" \
    || die "spill target '$to' is not one registered secondmate in $DATA/secondmates.md"
  # A local secondmate runs on this machine, so moving work there sheds none of
  # its load; only its own worker slots are relief.
  [ -z "$load_max" ] || [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] \
    || die "'load' needs a remote spill target; '$to' runs on this machine and shares its load"
fi

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

if [ "$spill_declared" = 0 ]; then
  printf 'spill: off\nreason: config/intake-spill declares no spill, so placement follows secondmate scope and its first rule\n'
  [ -z "$short" ] || printf 'short: %s\n' "$short"
else
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
fi

[ -n "$project" ] || exit 0
if [ -z "$first_id" ]; then
  first_none "config/intake-spill declares no first rule"
  exit 0
fi
case "$first_projects" in
  *" $project "*) ;;
  *)
    first_none "the first rule sends only$(printf '%s' "${first_projects% }") to $first_id"
    exit 0
    ;;
esac

# --- first-rule probe ---------------------------------------------------------
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
first_timeout=${FM_INTAKE_FIRST_TIMEOUT:-20}
[[ "$first_timeout" =~ ^[1-9][0-9]{0,3}$ ]] || die "FM_INTAKE_FIRST_TIMEOUT '$first_timeout' is not a positive number of seconds"

# remote <command> [args...]: run one tracked command in the secondmate's home,
# bounded. Sets remote_out and remote_rc; stderr is dropped because only the
# verdict matters here.
remote_out='' remote_rc=0
remote() {
  remote_rc=0
  remote_out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
    fm_run_timed "$first_timeout" "$SCRIPT_DIR/fm-on.sh" "$first_id" "$@" </dev/null 2>/dev/null) || remote_rc=$?
}

# Remote text reaches the task record and the backlog note, so keep it to one
# printable line.
one_line() { printf '%s' "$1" | tr -c '[:print:]' ' ' | cut -c1-200; }

first_verdict() {  # <first|fallback> <reason>
  local reason
  reason=$(one_line "$2")
  if [ "$1" = first ]; then
    printf 'first: %s\nfirst-reason: %s\n' "$first_id" "$reason"
    return 0
  fi
  printf 'first: fallback\nfirst-reason: %s\n' "$reason"
  # The captain hears about the first fallback once, not once per task. The
  # noclobber create is atomic, so two racing intakes tell him exactly once.
  # Without a state directory nothing can be recorded, so every fallback tells.
  if [ ! -d "$STATE" ] || (set -C && printf '%s %s\n' "$(date +%s)" "$reason" >"$STATE/.intake-first-told") 2>/dev/null; then
    printf 'first-notice: tell the captain\n'
  else
    printf 'first-notice: already told\n'
  fi
}

no_answer() {  # <rc> -> 0 when the call proves nothing answered
  case "$1" in 255 | 124 | 137 | 143) return 0 ;; esac
  return 1
}

remote fm-remote-secondmate-control.sh state "$first_id"
if no_answer "$remote_rc"; then
  first_verdict fallback "$first_id does not answer on its host $first_host"
  exit 0
fi
endpoint=$(printf '%s\n' "$remote_out" | tail -1)
if [ "$remote_rc" -ne 0 ]; then
  first_verdict fallback "the endpoint state of $first_id could not be read (fm-on.sh or the remote control exited $remote_rc)"
  exit 0
fi
if [ "$endpoint" != alive ]; then
  first_verdict fallback "$first_id is not running (endpoint ${endpoint:-unreadable})"
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  first_verdict fallback "this home has no jq, so $first_id's free slots cannot be read"
  exit 0
}
# fm-capacity.sh --json still prints its document when it exits 1 on an
# invalid config, so the document, not the exit status, decides.
remote fm-capacity.sh --json
if no_answer "$remote_rc"; then
  first_verdict fallback "$first_id stopped answering before its lane capacity was read"
  exit 0
fi
slots=$(printf '%s' "$remote_out" | jq -r '
  def nn: map(select(. != null));
  if type != "object" or .schema != "fm-lane-capacity.v1" then "none\tanswered without a lane capacity document"
  elif .cap.mode == "auto" then
    (.budget.by.memory) as $m | (.budget.by.ceiling) as $c
    | ([.gates[]? | select(.state == "closed" and (.name == "memory-pressure" or .name == "swap")) | .name]) as $mg
    | if $m == null then "0\tits memory cannot be measured"
      elif ($mg | length) > 0 then "0\tits \($mg | join(" and ")) gate is closed"
      else ([[$m, $c] | nn | min, 0] | max) as $s
        | "\($s)\t\($s) free slot(s) under its memory ceiling (\(.lanes.count) lane(s) running)" end
  elif .cap.status == "ok" then
    ([.verdict.reasons[]? | strings | select(startswith("memory"))]) as $mr
    | (.pressure.avail_gb) as $a | (.pressure.total_gb) as $t
    | (.limits.min_avail_gb // (if $t == null then 2 else ([$t * 0.10, 2] | max) end)) as $kept
    | if ($mr | length) > 0 then "0\t\($mr[0])"
      elif $a != null and ($a - $kept) < 1 then "0\tmemory: \($a) GB available, \($kept) GB kept"
      else ([.cap.target - .lanes.count, 0] | max) as $s
        | "\($s)\t\($s) free slot(s): \(.lanes.count) of \(.cap.target) lane(s) running" end
  elif .cap.status == "invalid" then "none\tits config/lane-capacity is invalid"
  else "none\tit declares no config/lane-capacity, so its free slots are not measured" end
' 2>/dev/null) || slots=
if [ -z "$slots" ]; then
  first_verdict fallback "$first_id's lane capacity could not be read (exit $remote_rc)"
  exit 0
fi
count=${slots%%$'\t'*}
why=${slots#*$'\t'}
if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
  first_verdict first "$first_id is running and has $why"
else
  first_verdict fallback "$first_id has no free slot: $why"
fi

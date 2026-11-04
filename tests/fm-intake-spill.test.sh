#!/usr/bin/env bash
# Behavior tests for bin/fm-intake-spill.sh: the intake placement check that
# tells firstmate whether this home is past its declared load or worker
# threshold and which registered secondmate takes the work that does not need
# this home.
#
# Every case drives the real script through its argv and environment, against
# a throwaway home with a real data/secondmates.md registry and real
# state/*.meta worker records. FM_INTAKE_SPILL_LOADAVG supplies the load so the
# verdict never depends on the machine running the suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-intake-spill.sh"
TMP_ROOT=$(fm_test_tmproot fm-intake-spill)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state"
printf '%s\n' "- offbox - Runs firstmate and skills work on the second machine. (host: offbox-ssh; root: /srv/firstmate; home: /srv/offbox; scope: firstmate and skills work that needs no main-machine access; projects: firstmate; added 2026-11-04)" \
  "- nextdoor - Runs docs work on this machine. (home: $TMP_ROOT/nextdoor; scope: docs work; projects: firstmate; added 2026-11-04)" \
  > "$HOME_DIR/data/secondmates.md"
DECL="$HOME_DIR/config/intake-spill"
code='' out='' err=''

run() {  # <code-var> <out-var> <err-var> [args...]
  local __code=$1 __out=$2 __err=$3 __o __e __c
  shift 3
  __o=$(FM_HOME="$HOME_DIR" "$TOOL" "$@" 2>"$TMP_ROOT/err") && __c=0 || __c=$?
  __e=$(cat "$TMP_ROOT/err")
  printf -v "$__code" '%s' "$__c"
  printf -v "$__out" '%s' "$__o"
  printf -v "$__err" '%s' "$__e"
}

workers() {  # <count>: replace the home's worker records with <count> ships plus one secondmate
  local i
  rm -f "$HOME_DIR"/state/*.meta
  fm_write_secondmate_meta "$HOME_DIR/state/offbox.meta" "$TMP_ROOT/offbox"
  i=0
  while [ "$i" -lt "$1" ]; do
    fm_write_meta "$HOME_DIR/state/ship-$i.meta" "kind=ship" "project=$HOME_DIR/projects/alpha"
    i=$((i + 1))
  done
}

# --- no declaration -----------------------------------------------------------

workers 3
FM_INTAKE_SPILL_LOADAVG=99 run code out err
expect_code 0 "$code" "no declaration exits 0"
assert_contains "$out" "spill: off" "no declaration reports off"
assert_not_contains "$out" "to:" "off names no target"
pass "an undeclared home is off and placement is scope alone"

# --- load threshold -----------------------------------------------------------

printf '%s\n' '# spill to the second machine when this one is busy' '  # an indented comment' 'to offbox' 'load 12' 'workers 10' 'short 15' > "$DECL"
FM_INTAKE_SPILL_LOADAVG=18.42 run code out err
expect_code 0 "$code" "a high load exits 0"
assert_contains "$out" "spill: yes" "load above threshold spills"
assert_contains "$out" "5-minute load 18.42 is above 12" "reason names the load"
assert_contains "$out" "to: offbox" "the named secondmate takes the spill"
assert_contains "$out" "workers: 3 (at 10 spills)" "workers exclude the secondmate record"
assert_contains "$out" "short: 15" "short-task minutes are printed"
FM_INTAKE_SPILL_LOADAVG=12 run code out err
assert_contains "$out" "spill: no" "load equal to the threshold does not spill"
assert_contains "$out" "below every declared threshold" "a quiet home says why it keeps work"
pass "the load threshold spills only above its value"

# --- worker threshold ---------------------------------------------------------

workers 10
FM_INTAKE_SPILL_LOADAVG=2.5 run code out err
assert_contains "$out" "spill: yes" "worker records at the threshold spill"
assert_contains "$out" "10 worker records reach the 10-worker threshold" "reason names the worker count"
FM_INTAKE_SPILL_LOADAVG=20 run code out err
assert_contains "$out" "5-minute load 20 is above 12; 10 worker records" "both reasons are named together"
workers 9
FM_INTAKE_SPILL_LOADAVG=2.5 run code out err
assert_contains "$out" "spill: no" "one worker under the threshold keeps work home"
pass "the worker threshold spills at its count"

# --- unmeasurable load --------------------------------------------------------

FM_INTAKE_SPILL_LOADAVG=garbage run code out err
expect_code 0 "$code" "an unreadable load still exits 0"
assert_contains "$out" "spill: no" "an unknown load never spills by itself"
assert_contains "$out" "load: unknown" "an unknown load is disclosed"
workers 10
FM_INTAKE_SPILL_LOADAVG=garbage run code out err
assert_contains "$out" "spill: yes" "the worker threshold still applies when load is unknown"
pass "an unmeasurable load is disclosed and leaves the worker threshold in force"

# --- local spill target -------------------------------------------------------

printf '%s\n' 'to nextdoor' 'workers 10' > "$DECL"
FM_INTAKE_SPILL_LOADAVG=40 run code out err
expect_code 0 "$code" "a local target with only a worker threshold is readable"
assert_contains "$out" "spill: yes" "a local target still relieves this home's worker slots"
assert_contains "$out" "to: nextdoor" "the local target takes the worker spill"
pass "a local secondmate can take a worker-slot spill"

# --- unreadable declarations ----------------------------------------------------

bad() {  # <label> <expected-stderr> <lines...>
  local label=$1 want=$2
  shift 2
  printf '%s\n' "$@" > "$DECL"
  FM_INTAKE_SPILL_LOADAVG=1 run code out err
  expect_code 2 "$code" "$label exits 2"
  assert_contains "$err" "$want" "$label names the problem"
  assert_not_contains "$out" "spill:" "$label prints no verdict"
}
bad "missing target" "names no 'to" 'load 12'
bad "no threshold" "neither 'load' nor 'workers'" 'to offbox' 'short 15'
bad "unregistered target" "is not one registered secondmate" 'to elsewhere' 'load 12'
bad "duplicate key" "declared twice" 'to offbox' 'load 12' 'load 14'
bad "unknown key" "unknown key 'cap'" 'to offbox' 'cap 12'
bad "malformed load" "is not a non-negative number" 'to offbox' 'load high'
bad "zero workers" "is not a positive integer" 'to offbox' 'workers 0'
bad "load to a local target" "needs a remote spill target" 'to nextdoor' 'load 12'
bad "extra field" "expected '<key> <value>'" 'to offbox load 12'
run code out err extra
expect_code 2 "$code" "an argument is a usage error"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" "Usage: fm-intake-spill.sh" "--help prints usage"
pass "an unreadable declaration exits 2 and is never treated as off"

printf '# all fm-intake-spill tests passed\n'

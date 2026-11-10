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
#
# The first-rule cases drive the real bin/fm-on.sh route with a stubbed ssh
# (the FM_SSH_BIN seam): the stub decodes the remote command it was asked to
# run and answers the endpoint state from FM_FAKE_STATE and the remote lane
# capacity document from the file FM_FAKE_CAPACITY names, so no case reaches a
# real host.
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

# --- first rule ---------------------------------------------------------------

FAKE_SSH="$TMP_ROOT/fake-ssh"
SSH_LOG="$TMP_ROOT/ssh.log"
CAP_DOC="$TMP_ROOT/capacity.json"
cat > "$FAKE_SSH" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
cmd=$(printf '%s' "$last" | { base64 -d 2>/dev/null || base64 -D; } | tr '\0' ' ')
printf '%s\n' "$cmd" >> "$FM_FAKE_SSH_LOG"
[ -z "${FM_FAKE_SSH_SLEEP:-}" ] || sleep "$FM_FAKE_SSH_SLEEP"
[ "${FM_FAKE_SSH_RC:-0}" = 0 ] || exit "$FM_FAKE_SSH_RC"
case "$cmd" in
  fm-remote-secondmate-control.sh*) printf '%s\n' "${FM_FAKE_STATE:-alive}" ;;
  fm-capacity.sh*) cat "$FM_FAKE_CAPACITY" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_SSH"

first_run() {  # <code-var> <out-var> <err-var> [args...]: run with the stubbed transport
  : > "$SSH_LOG"
  FM_SSH_BIN="$FAKE_SSH" FM_FAKE_SSH_LOG="$SSH_LOG" FM_FAKE_CAPACITY="$CAP_DOC" run "$@"
}

auto_doc() {  # <memory> <ceiling|null> [gate-json]: an auto-mode remote document
  printf '{"schema":"fm-lane-capacity.v1","lanes":{"count":2},"cap":{"target":null,"status":"none","mode":"auto"},"reserve":{"flag":"present","label":"gaming"},"captain":"present","budget":{"by":{"memory":%s,"cpu":0,"disk":9,"ceiling":%s}},"gates":[%s],"verdict":{"admit":false,"free_lanes":0,"reasons":["cpu: load 31 on 16 cores","captain reserve: gaming"]}}\n' \
    "$1" "$2" "${3:-}" > "$CAP_DOC"
}

fixed_doc() {  # <target> <lanes> [reason]: a fixed-cap remote document
  printf '{"schema":"fm-lane-capacity.v1","lanes":{"count":%s},"cap":{"target":%s,"status":"ok"},"verdict":{"admit":false,"free_lanes":0,"reasons":[%s]}}\n' \
    "$2" "$1" "${3:+\"$3\"}" > "$CAP_DOC"
}

rm -f "$HOME_DIR/state/.intake-first-told"
workers 3
printf '%s\n' 'first offbox firstmate skills offline-business' > "$DECL"
auto_doc 3 5
first_run code out err
expect_code 0 "$code" "a first-only declaration is readable"
assert_contains "$out" "spill: off" "a first-only declaration declares no spill"
assert_not_contains "$out" "first:" "without --project the rule is not judged"
[ ! -s "$SSH_LOG" ] || fail "a run without --project reached the remote host: $(cat "$SSH_LOG")"
first_run code out err --project firstmate
expect_code 0 "$code" "a first-rule project exits 0"
assert_contains "$out" "first: offbox" "a running secondmate with free slots takes the work"
assert_contains "$out" "first-reason: offbox is running and has 3 free slot(s) under its memory ceiling" "the reason names the free slots"
assert_not_contains "$out" "first-notice:" "only a fallback carries a notice"
assert_contains "$(cat "$SSH_LOG")" "fm-remote-secondmate-control.sh state offbox" "the probe reads the endpoint state"
assert_contains "$(cat "$SSH_LOG")" "fm-capacity.sh --json" "the probe reads the remote lane capacity"
first_run code out err --project alpha
assert_contains "$out" "first: none" "a project outside the rule is not placed by it"
assert_contains "$out" "sends only firstmate skills offline-business to offbox" "the reason names the rule's projects"
[ ! -s "$SSH_LOG" ] || fail "a project outside the rule reached the remote host"
pass "a first rule sends its projects to a running secondmate with free slots"

auto_doc 2 null
first_run code out err --project skills
assert_contains "$out" "first: offbox" "cpu load, a reserve flag, and captain presence never close the rule"
auto_doc 9 1
first_run code out err --project skills
assert_contains "$out" "has 1 free slot(s)" "the lane ceiling bounds the memory slots"
pass "free slots count memory and the lane ceiling only, so gaming does not make the secondmate unavailable"

assert_absent "$HOME_DIR/state/.intake-first-told" "no fallback yet, so nothing was told"
FM_FAKE_SSH_RC=255 first_run code out err --project firstmate
expect_code 0 "$code" "an unreachable secondmate still exits 0"
assert_contains "$out" "first: fallback" "an unreachable secondmate falls back"
assert_contains "$out" "first-reason: offbox does not answer on its host offbox-ssh" "the reason names the silent host"
assert_contains "$out" "first-notice: tell the captain" "the first fallback asks to tell the captain"
assert_present "$HOME_DIR/state/.intake-first-told" "the first fallback is recorded"
FM_FAKE_STATE=dead first_run code out err --project firstmate
assert_contains "$out" "first-reason: offbox is not running (endpoint dead)" "a dead secondmate falls back"
assert_contains "$out" "first-notice: already told" "a later fallback does not tell the captain again"
FM_FAKE_SSH_SLEEP=5 FM_INTAKE_FIRST_TIMEOUT=1 first_run code out err --project firstmate
assert_contains "$out" "does not answer" "a timed-out probe counts as no answer"
pass "an unreachable or stopped secondmate falls back, and the captain is told only once"

nofree() {  # <label> <expected-reason>
  first_run code out err --project offline-business
  assert_contains "$out" "first: fallback" "$1 falls back"
  assert_contains "$out" "$2" "$1 names why"
}
auto_doc 0 4
nofree "no memory room" "offbox has no free slot: 0 free slot(s) under its memory ceiling"
auto_doc 4 4 '{"name":"memory-pressure","state":"closed"}'
nofree "a closed memory-pressure gate" "its memory-pressure gate is closed"
auto_doc null 4
nofree "unmeasurable memory" "its memory cannot be measured"
fixed_doc 4 4
nofree "a full fixed cap" "0 free slot(s): 4 of 4 lane(s) running"
fixed_doc 4 1 "memory: 6% free"
nofree "a fixed-cap memory constraint" "memory: 6% free"
printf '{"schema":"fm-lane-capacity.v1","lanes":{"count":0},"cap":{"target":null,"status":"none"}}\n' > "$CAP_DOC"
nofree "no remote lane capacity" "declares no config/lane-capacity"
printf 'not json\n' > "$CAP_DOC"
nofree "an unreadable answer" "lane capacity could not be read"
fixed_doc 4 1
first_run code out err --project offline-business
assert_contains "$out" "first: offbox" "a fixed cap with room takes the work"
assert_contains "$out" "3 free slot(s): 1 of 4 lane(s) running" "the fixed-cap reason names the lanes"
pass "a secondmate with no free slot under its memory ceiling falls back with the reason"

printf '%s\n' 'to offbox' 'workers 10' 'first offbox firstmate' > "$DECL"
FM_INTAKE_SPILL_LOADAVG=1 first_run code out err --project firstmate
assert_contains "$out" "spill: no" "a spill and a first rule are judged together"
assert_contains "$out" "first: offbox" "the first rule is judged beside the spill"
bad "a local first secondmate" "'first' needs a remote secondmate" 'first nextdoor firstmate'
bad "an unregistered first secondmate" "is not one registered secondmate" 'first elsewhere firstmate'
bad "a first rule with no project" "expected 'first <secondmate-id> <project>...'" 'first offbox'
bad "a first rule named twice" "declared twice" 'first offbox firstmate' 'first offbox skills'
run code out err --project
expect_code 2 "$code" "--project without a name is a usage error"
run code out err --project 'a/b'
expect_code 2 "$code" "--project with a path is a usage error"
pass "a malformed first rule exits 2"

printf '# all fm-intake-spill tests passed\n'

#!/usr/bin/env bash
# Behavior tests for a dead runner generation's orphaned source child and for
# the Lavish LISTENER_ACTIVE result it causes.
#
# A runner leader that dies on its own from a catchable signal runs its exit
# trap, which releases the source claim while its polling child - the Lavish
# poll wrapper and its `lavish-axi poll` - keeps running in the dead leader's
# process group and keeps the board's one listener slot. Every later runner
# for that source then gets LISTENER_ACTIVE. These tests drive the real adapter
# and runner against a fake `lavish-axi` that keeps exactly that one-listener
# rule, then check that session start stops the orphan by its recorded pid and
# start stamp, leaves a live generation and another home alone, and that a
# LISTENER_ACTIVE capture never wakes the helm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-orphan-poll)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1
mkdir -p "$LAVISH_AXI_STATE_DIR"

# Process groups this suite orphaned on purpose. A released claim leaves them
# outside every home sweep, so the suite stops exactly these groups itself.
ORPHAN_GROUPS="$TMP_ROOT/orphan-groups"
: > "$ORPHAN_GROUPS"
reap_orphan_groups() {
  local group
  while IFS= read -r group; do
    case "$group" in ''|*[!0-9]*) continue ;; esac
    kill -KILL -"$group" 2>/dev/null || true
  done < "$ORPHAN_GROUPS"
}
trap 'reap_orphan_groups; fm_test_cleanup' EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` with the server's one-listener rule:
# the first poll of a board holds its listener until released, and a second
# poll is refused with the exact LISTENER_ACTIVE response lavish-axi prints.
[ "${1-}" != --version ] || { printf '0.1.80\n'; exit 0; }
[ "${1-}" = poll ] || exit 0
lock="$LAVISH_LISTENER_DIR/held"
if ! mkdir "$lock" 2>/dev/null; then
  printf '%s\n' \
    'error: Lavish Editor already has an active poll listener (current listener: none; active for 1200ms)' \
    'code: LISTENER_ACTIVE' \
    'help[1]: Use --takeover only when you intend to displace the current listener'
  exit 1
fi
printf '%s\n' "$$" > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
trap 'exit 143' TERM
trap 'exit 129' HUP
while [ ! -e "$LAVISH_RELEASE" ]; do sleep 0.05; done
printf 'session:\n  status: ended\n'
SH
chmod +x "$FAKEBIN/lavish-axi"
export PATH="$FAKEBIN:$PATH"

lavish_session() {  # <artifact>
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open",
      url => "http://127.0.0.1:14387/session/$key",
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1"
}

until_true() {  # <tenths> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

pe() { FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
wake_count() { [ -s "$1/state/.wake-queue" ] && grep -c . "$1/state/.wake-queue" || printf '0\n'; }
listener_pid() { cat "$1/held/pid" 2>/dev/null; }
listener_held() { [ -s "$1/held/pid" ]; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
group_gone() { ! kill -0 -"$1" 2>/dev/null; }

# new_board <name>: a home with one firstmate-owned board whose fake listener
# lives under its own directory. Prints "<home> <source-id> <listener-dir>".
new_board() {
  local name=$1 home art listen
  home="$TMP_ROOT/$name/home"
  listen="$TMP_ROOT/$name/listener"
  art="$TMP_ROOT/$name/board.html"
  mkdir -p "$home/state" "$listen"
  printf '<h1>%s</h1>\n' "$name" > "$art"
  lavish_session "$art"
  fm_test_track_procevent_home "$home"
  LAVISH_LISTENER_DIR="$listen" LAVISH_RELEASE="$TMP_ROOT/$name/release" FM_HOME="$home" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$art" >/dev/null || fail "$name: arm failed"
  printf '%s %s %s\n' "$home" "$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$art")" "$listen"
}

# orphan_board <home> <source-id> <listener-dir>: signal the live runner leader
# alone, the way a dying session's signal can reach it, and print its group.
orphan_board() {
  local home=$1 id=$2 listen=$3 runner
  until_true 100 listener_held "$listen" || fail "$id: the first poll never took the listener"
  runner=$(cat "$home/state/procevent/$id.runner") || fail "$id: no runner record"
  printf '%s\n' "$runner" >> "$ORPHAN_GROUPS"
  kill -TERM "$runner"
  until_true 50 pid_gone "$runner" || fail "$id: the runner leader did not exit"
  printf '%s\n' "$runner"
}

# --- LISTENER_ACTIVE is a silent, nonterminal no-op -----------------------
RESULTS="$TMP_ROOT/results"
mkdir -p "$RESULTS"
printf '%s\n' \
  'error: Lavish Editor already has an active poll listener (current listener: none; active for 1200ms)' \
  'code: LISTENER_ACTIVE' \
  'help[1]: Use --takeover only when you intend to displace the current listener' \
  > "$RESULTS/active.result"
printf '%s\n' \
  'error: Lavish Editor already has an active poll listener' \
  'code: LISTENER_ACTIVE' \
  > "$RESULTS/active-bare.result"
printf '%s\n' \
  'error: Lavish Editor already has an active poll listener' \
  'code: LISTENER_ACTIVE' \
  'prompts[1]{uid,prompt,selector,tag,text}:' \
  '  "1","keep this","","message",""' \
  > "$RESULTS/active-with-content.result"
printf '%s\n' \
  'error: Lavish Editor poll listener was replaced by a takeover' \
  'code: LISTENER_REPLACED' \
  > "$RESULTS/replaced.result"
LAVISH="$ROOT/bin/fm-procevent-lavish.sh"
assert_equals listener-active "$("$LAVISH" classify "$RESULTS/active.result")" \
  "a LISTENER_ACTIVE poll must classify listener-active"
assert_equals listener-active "$("$LAVISH" classify "$RESULTS/active-bare.result")" \
  "a LISTENER_ACTIVE poll without its help line must classify listener-active"
"$LAVISH" silent "$RESULTS/active.result" \
  || fail "a LISTENER_ACTIVE capture carries nothing and must be silent"
"$LAVISH" silent "$RESULTS/active-bare.result" \
  || fail "a LISTENER_ACTIVE capture without its help line must be silent"
! "$LAVISH" terminal "$RESULTS/active.result" \
  || fail "a LISTENER_ACTIVE capture must keep the board armed"
! "$LAVISH" silent "$RESULTS/active-with-content.result" \
  || fail "a LISTENER_ACTIVE code followed by content must still be announced"
assert_equals unknown "$("$LAVISH" classify "$RESULTS/replaced.result")" \
  "LISTENER_REPLACED is a takeover, not this no-op"
! "$LAVISH" silent "$RESULTS/replaced.result" \
  || fail "a LISTENER_REPLACED capture must still be announced"
pass "LISTENER_ACTIVE classifies listener-active, stays silent, and keeps the board armed"

# --- an orphaned poll no longer wakes the helm -----------------------------
read -r H1 ID1 L1 < <(new_board quiet)
ORPHAN1=$(listener_pid "$L1")
orphan_board "$H1" "$ID1" "$L1" >/dev/null || exit 1
kill -0 "$ORPHAN1" 2>/dev/null \
  || fail "fixture: the orphaned listener should outlive its runner leader"
LAVISH_LISTENER_DIR="$L1" LAVISH_RELEASE="$TMP_ROOT/quiet/release" pe "$H1" reconcile >/dev/null 2>&1 || true
until_true 100 test -e "$H1/state/procevent-inbox/$ID1.1.result" \
  || fail "the next runner never captured its colliding poll"
runner_finished() { [ ! -e "$1/state/procevent/$2.runner" ]; }
until_true 100 runner_finished "$H1" "$ID1" || fail "the colliding runner did not finish its round"
assert_equals 0 "$(wake_count "$H1")" \
  "a LISTENER_ACTIVE capture from a colliding poll must not wake the helm"
pass "a poll that collides with an orphaned listener is recorded without a wake"

# --- session start stops a dead generation's orphan, by recorded pid -------
read -r H2 ID2 L2 < <(new_board restart)
ORPHAN2=$(listener_pid "$L2")
GROUP2=$(orphan_board "$H2" "$ID2" "$L2") || exit 1
read -r H3 ID3 L3 < <(new_board live)
until_true 100 listener_held "$L3" || fail "live: the first poll never took the listener"
LIVE3=$(listener_pid "$L3")
read -r H4 ID4 L4 < <(new_board elsewhere)
ORPHAN4=$(listener_pid "$L4")
GROUP4=$(orphan_board "$H4" "$ID4" "$L4") || exit 1

OUT=$(pe "$H2" retire-orphans 2>&1) || fail "retire-orphans failed: $OUT"
assert_contains "$OUT" "orphan-stopped: $ID2" "retire-orphans must name the source whose orphan it stopped"
until_true 50 pid_gone "$ORPHAN2" || fail "the dead generation's listener survived retire-orphans"
until_true 50 group_gone "$GROUP2" || fail "the dead generation's process group survived retire-orphans"
kill -0 "$ORPHAN4" 2>/dev/null || fail "another home's orphan was touched"
kill -0 -"$GROUP4" 2>/dev/null || fail "another home's orphaned group was touched"

OUT=$(pe "$H3" retire-orphans 2>&1) || fail "retire-orphans failed on a live home: $OUT"
assert_not_contains "$OUT" "orphan-stopped" "a live generation must not be reported as an orphan"
kill -0 "$LIVE3" 2>/dev/null || fail "a live generation's listener was stopped"

OUT=$(pe "$H2" retire-orphans 2>&1) || fail "a repeated retire-orphans failed: $OUT"
assert_not_contains "$OUT" "orphan-stopped" "a stopped orphan must not be stopped twice"

LAVISH_LISTENER_DIR="$L2" LAVISH_RELEASE="$TMP_ROOT/restart/release" pe "$H2" reconcile >/dev/null 2>&1 || true
until_true 100 listener_held "$L2" || fail "the source did not listen again after its orphan was stopped"
[ "$(listener_pid "$L2")" != "$ORPHAN2" ] || fail "the listener is still the orphan"
assert_equals 0 "$(wake_count "$H2")" "recovery from an orphan must not wake the helm"
pass "retire-orphans stops only this home's dead generation and the board listens again"

# --- a reused pid is never signalled -------------------------------------
# The record names the orphan's pid but a start stamp no live process has, as
# after pid reuse: the group must be left alone and the record dropped.
for record in "$H4"/state/procevent/.*.child; do
  [ -f "$record" ] || continue
  sed 's/^child_start=.*/child_start=not-this-process/' "$record" > "$record.tmp" && mv -f "$record.tmp" "$record"
done
OUT=$(pe "$H4" retire-orphans 2>&1) || fail "retire-orphans failed on a mismatched record: $OUT"
assert_not_contains "$OUT" "orphan-stopped" "a child whose start stamp differs must not be stopped"
kill -0 "$ORPHAN4" 2>/dev/null || fail "a pid whose start stamp differs from the record was signalled"
set -- "$H4"/state/procevent/.*.child
[ ! -e "$1" ] || fail "a record whose child cannot be proved should be dropped"
kill -KILL -"$GROUP4" 2>/dev/null || true
pass "a recorded pid whose start stamp no longer matches is never signalled"

# --- session start runs the sweep ------------------------------------------
read -r H5 ID5 L5 < <(new_board session)
ORPHAN5=$(listener_pid "$L5")
orphan_board "$H5" "$ID5" "$L5" >/dev/null || exit 1
WORLD_ROOT="$TMP_ROOT/session/root"
git init -q -b main "$WORLD_ROOT"
git -C "$WORLD_ROOT" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
mkdir -p "$H5/data" "$H5/config"
SS_OUT=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_HOME="$H5" FM_ROOT_OVERRIDE="$WORLD_ROOT" "$ROOT/bin/fm-session-start.sh" 2>&1) || true
until_true 50 pid_gone "$ORPHAN5" || fail "a locked session start left the dead generation's listener running"
assert_contains "$SS_OUT" "BOOTSTRAP_INFO: orphan-stopped: $ID5" \
  "session start must report the orphan it stopped as a completed fact"
pass "a locked session start stops a dead generation's orphaned poll"

printf 'all fm-procevent-orphan-poll tests passed\n'

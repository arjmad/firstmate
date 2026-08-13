#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    # Every lab this fake knows about, so the cross-task reap sweep has a real
    # multi-session list to judge (a single-session list could not distinguish
    # owned, foreign, and legacy-shaped labs).
    labs='[]'
    for path in "$state"/fm-lab-*; do
      [ -f "$path" ] || continue
      name=${path##*/}
      value=$(cat "$path")
      [ "$value" != deleted ] || continue
      running=false
      [ "$value" = running ] && running=true
      labs=$(printf '%s' "$labs" | jq -c --arg name "$name" --argjson running "$running" \
        '. + [{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]')
    done
    jq -nc --arg socket "$default_socket" --argjson labs "$labs" \
      '{sessions:([{default:true,name:"default",running:true,socket_path:$socket}] + $labs)}'
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_teardown_task_removes_owned_session() {
  local task_id=collision-prefix-alpha sibling_id=collision-prefix-bravo name sibling
  name=$(fm_herdr_lab_name "$task_id")
  sibling=$(fm_herdr_lab_name "$sibling_id")
  run_with_fake fm_herdr_lab_provision "$name" || fail "task teardown fixture provision failed"
  run_with_fake fm_herdr_lab_provision "$sibling" || fail "sibling teardown fixture provision failed"
  run_with_fake fm_herdr_lab_teardown_task "$task_id" || fail "task teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "task teardown did not delete its owned lab session"
  [ "$(cat "$FAKE_STATE/$sibling")" = running ] || fail "task teardown deleted a colliding sibling lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "task teardown left its ownership tripwire"
  assert_present "$TRIPWIRES/$sibling.fleet-state.json" "task teardown removed the sibling ownership tripwire"
  run_with_fake fm_herdr_lab_teardown_task "$sibling_id" || fail "sibling task teardown failed"
  pass "fm-herdr-lab: task teardown removes only exact ownership when truncated labels collide"
}

assert_lab_untouched() { # <session> <message>
  [ "$(cat "$FAKE_STATE/$1")" = running ] || fail "$2"
  if grep -E '^session (stop|delete) ' "$FAKE_LOG" | grep -F "$1" >/dev/null; then
    fail "$2 (destructive Herdr call reached it)"
  fi
}

test_reap_requires_positive_same_home_ownership() {
  local old_state=$FAKE_STATE old_tripwires=$TRIPWIRES reap_home foreign_home lab live stale murky foreign collide token_owned out
  fm_herdr_lab_meta_agent_state() {
    grep '^lab-agent-state=' "$1" | cut -d= -f2-
  }
  reap_home="$TMP_ROOT/reap-home"
  foreign_home="$TMP_ROOT/reap-foreign-home"
  FAKE_STATE="$TMP_ROOT/reap-herdr-state"
  TRIPWIRES="$TMP_ROOT/reap-tripwires"
  mkdir -p "$FAKE_STATE" "$TRIPWIRES" "$reap_home/state" "$foreign_home/state"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  # Owned names are minted under the SAME effective home the reap below runs
  # as: the ownership token is home-scoped, so a name minted elsewhere would
  # simply be foreign.
  live=$(FM_STATE_OVERRIDE="$reap_home/state" fm_herdr_lab_name live-task)
  stale=$(FM_STATE_OVERRIDE="$reap_home/state" fm_herdr_lab_name stale-task)
  murky=$(FM_STATE_OVERRIDE="$reap_home/state" fm_herdr_lab_name murky-task)
  # A lab provisioned by another Firstmate home for the SAME task id this home
  # records as dead. The tripwire directory is UID-global so its ownership
  # record is visible here, but the home-scoped token never matches this home's
  # records, so the other home's live lab stays unproven here.
  foreign=$(FM_STATE_OVERRIDE="$foreign_home/state" fm_herdr_lab_name stale-task)
  # A pre-token legacy-shaped lab name: it carries no home-scoped token, so no
  # task record can claim it and it must stay unproven, never reapable.
  collide="fm-lab-alpha-beta-$$-7"
  # Task id herdr-lab-cleanup truncates to the stem herdr-lab, which is also a
  # sibling task's full id. The exact task token decides ownership.
  token_owned=$(FM_STATE_OVERRIDE="$reap_home/state" fm_herdr_lab_name herdr-lab-cleanup)
  for lab in "$live" "$stale" "$murky" "$foreign" "$collide" "$token_owned"; do
    printf '%s\n' running > "$FAKE_STATE/$lab"
    printf '%s\n' '{"name":"default","default":true,"running":true,"socket_path":"/home/test/.config/herdr/herdr.sock"}' \
      > "$TRIPWIRES/$lab.fleet-state.json"
  done
  printf '%s\n' 'window=default:test' 'lab-agent-state=alive' > "$reap_home/state/live-task.meta"
  printf '%s\n' 'window=default:gone' 'lab-agent-state=dead' > "$reap_home/state/stale-task.meta"
  printf '%s\n' 'window=default:murky' 'lab-agent-state=ambiguous' > "$reap_home/state/murky-task.meta"
  printf '%s\n' 'window=default:a' 'lab-agent-state=missing' > "$reap_home/state/alpha.meta"
  printf '%s\n' 'window=default:ab' 'lab-agent-state=missing' > "$reap_home/state/alpha-beta.meta"
  printf '%s\n' 'window=default:stem' 'lab-agent-state=dead' > "$reap_home/state/herdr-lab-cleanup.meta"
  printf '%s\n' 'window=default:sib' 'lab-agent-state=ambiguous' > "$reap_home/state/herdr-lab.meta"

  : > "$FAKE_LOG"
  out=$(FM_HOME="$reap_home" FM_STATE_OVERRIDE="$reap_home/state" run_with_fake fm_herdr_lab_reap) \
    || fail "dry-run reap should report without mutating"
  printf '%s\n' "$out" | grep -F "keep live task lab: $live" >/dev/null \
    || fail "dry-run reap did not protect the live task lab: $out"
  printf '%s\n' "$out" | grep -F "dry-run stale task lab: $stale" >/dev/null \
    || fail "dry-run reap did not identify the proven stale lab: $out"
  printf '%s\n' "$out" | grep -F "leave unproven lab: $murky" >/dev/null \
    || fail "dry-run reap did not report the ambiguous-state lab by exact name: $out"
  printf '%s\n' "$out" | grep -F "leave unproven lab: $foreign" >/dev/null \
    || fail "dry-run reap did not report the foreign-home lab by exact name: $out"
  printf '%s\n' "$out" | grep -F "leave unproven lab: $collide" >/dev/null \
    || fail "dry-run reap did not report the unclaimed legacy-shaped lab by exact name: $out"
  printf '%s\n' "$out" | grep -F "dry-run stale task lab: $token_owned" >/dev/null \
    || fail "dry-run reap let a sibling's label prefix outvote the exact task token: $out"
  assert_lab_untouched "$live" "dry-run reap changed the live lab"
  assert_lab_untouched "$stale" "dry-run reap changed the stale lab"
  assert_lab_untouched "$foreign" "dry-run reap changed the foreign-home lab"

  : > "$FAKE_LOG"
  out=$(FM_HOME="$reap_home" FM_STATE_OVERRIDE="$reap_home/state" \
    run_with_fake fm_herdr_lab_reap --apply) \
    || fail "apply reap must sweep its own proven-dead labs even while other labs stay unproven"
  printf '%s\n' "$out" | grep -F "removed stale task lab: $stale" >/dev/null \
    || fail "apply reap did not report removing the proven stale lab: $out"
  [ "$(cat "$FAKE_STATE/$stale")" = deleted ] || fail "apply reap did not delete the proven stale lab"
  [ "$(cat "$FAKE_STATE/$token_owned")" = deleted ] \
    || fail "apply reap did not delete the lab whose exact task token proves dead ownership"
  assert_lab_untouched "$live" "apply reap deleted a live task lab"
  assert_lab_untouched "$murky" "apply reap deleted a lab with an ambiguous agent state"
  assert_lab_untouched "$foreign" "apply reap deleted another home's lab for a task id this home records as dead"
  assert_lab_untouched "$collide" "apply reap deleted a legacy-shaped lab no token claims"
  assert_present "$TRIPWIRES/$foreign.fleet-state.json" "apply reap removed a foreign home's ownership record"

  FAKE_STATE=$old_state
  TRIPWIRES=$old_tripwires
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-herdr-lab.sh"
  pass "fm-herdr-lab: reaping is dry-run by default and destroys only token-owned same-home labs proven dead"
}

test_task_stem_backs_both_naming_and_task_prefix() {
  local task_id name prefix
  for task_id in lab a collision-prefix-alpha collision-prefix-bravo \
    ...leading-dots 1234567890-trailing very-long-task-id-that-truncates task.id_2; do
    name=$(fm_herdr_lab_name "$task_id") || fail "name derivation failed for '$task_id'"
    prefix=$(fm_herdr_lab_task_prefix "$task_id") || fail "task prefix derivation failed for '$task_id'"
    case "$name" in
      "$prefix"*) ;;
      *) fail "generated name '$name' does not carry the task teardown prefix '$prefix'" ;;
    esac
    fm_herdr_lab_validate_name "$name" || fail "generated name '$name' is not a valid lab session name"
  done
  pass "fm-herdr-lab: one task stem backs both session naming and task-scoped teardown"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown

test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_teardown_task_removes_owned_session
test_reap_requires_positive_same_home_ownership
test_task_stem_backs_both_naming_and_task_prefix
test_timed_out_provision_cancels_late_launch

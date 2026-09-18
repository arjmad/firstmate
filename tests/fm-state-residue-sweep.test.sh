#!/usr/bin/env bash
# tests/fm-state-residue-sweep.test.sh - the locked-session-start retirement of
# the watcher's per-endpoint bookkeeping owned by bin/fm-state-residue-sweep.sh,
# and its seat among bin/fm-bootstrap.sh's MUTATING sweeps.
#
# The gap under test (evidence 2026-09-17): bin/fm-watch.sh keeps a family of
# marker files per supervised endpoint (.hash-<key>, .count-<key>, ...), the
# watcher only polls endpoints a current state/<id>.meta names, and nothing
# ever removed the markers of a pane that died without a teardown, so one home
# had accumulated 1,935 dotfiles for panes dead since 2026-08-25.
#
# The guarantees under test:
#   - An endpoint the backend positively reports missing has every one of its
#     marker files removed, and only those.
#   - A live endpoint's markers are kept even without a task record.
#   - An ambiguous or unreadable backend answer keeps the markers.
#   - Markers keyed by any current state/<id>.meta target are never queried.
#   - A key that no candidate backend/session fits is kept untouched.
#   - The lossy key derivation cannot delete a live window's markers: a live
#     `fm-a.b` window covers the key `fm-a_b` shares with it.
#   - The scratch files of the Claude Stop auto-arm and the wake drain rotate
#     only once older than the documented age, and never while fresh.
#   - The read-only session path (FM_BOOTSTRAP_DETECT_ONLY=1) runs no sweep.
#   - --dry-run reports the same verdicts and removes nothing.
#   - Silence when nothing was removed; one BOOTSTRAP_INFO line otherwise.
#   - One run asks at most the documented question budget and reports the
#     remainder as deferred, which the next run then finishes.
#   - The Herdr candidate: a pane_not_found pane and a positively stopped
#     server retire markers; a live pane and an unparseable snapshot keep them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-state-residue-sweep)
SWEEP="$ROOT/bin/fm-state-residue-sweep.sh"

# The twelve per-endpoint marker prefixes the watcher writes, as the sweep
# must know them. Kept here as the test's own expectation of the on-disk
# family, exercised through the script rather than read from it.
PREFIXES='.hash- .count- .stale- .stale-since- .wedge-escalations- .churn-since- .paused- .paused-rechecked- .paused-resurfaced- .writing-since- .writing-resurfaced- .waiting-resurfaced-'

# make_tmux <dir>: a tmux stub whose session inventory and per-window
# foreground process are driven by the fixture file FM_TEST_TMUX_WORLD:
#   windows=<space-separated names>   the `firstmate` session's live windows
#   inventory=ok|fail                 whether list-windows can be read at all
#   fg=<command>                      #{pane_current_command} of every window
make_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
world=${FM_TEST_TMUX_WORLD:?}
val() { sed -n "s/^$1=//p" "$world" | tail -1; }
printf '%s\n' "$*" >> "${FM_TEST_TMUX_CALLS:?}"
case "${1:-}" in
  list-windows)
    [ "$(val inventory)" = ok ] || { printf '%s\n' "permission denied" >&2; exit 1; }
    for w in $(val windows); do printf '%s\n' "$w"; done
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf '%s\n' "$(val fg)"; exit 0 ;;
        *pane_pid*) printf '%s\n' 4242; exit 0 ;;
      esac
    done
    printf '%s\n' firstmate
    exit 0
    ;;
  list-panes) printf '%s\n' "$(val fg)"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_home <name>: a scratch home whose config pins the tmux backend so the
# sweep's ambient candidate is deterministic wherever the suite runs.
new_home() {
  local name=$1 h
  h="$TMP_ROOT/$name/home"
  mkdir -p "$h/state" "$h/config"
  printf 'tmux\n' > "$h/config/backend"
  printf '%s\n' "$h"
}

seed_markers() {  # <home> <key>
  local home=$1 key=$2 p
  for p in $PREFIXES; do
    printf 'x' > "$home/state/$p$key"
  done
}

count_markers() {  # <home> <key>
  local home=$1 key=$2 p n=0
  for p in $PREFIXES; do
    [ -e "$home/state/$p$key" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

world() {  # <home> <windows> <inventory> <fg>
  local home=$1
  {
    printf 'windows=%s\n' "$2"
    printf 'inventory=%s\n' "$3"
    printf 'fg=%s\n' "$4"
  } > "$home/world"
}

run_sweep() {  # <fakebin> <home> [args...]
  local fb=$1 home=$2
  shift 2
  PATH="$fb:$BASE_PATH" TMUX='' HERDR_ENV='' FM_HOME="$home" \
    FM_TEST_TMUX_WORLD="$home/world" FM_TEST_TMUX_CALLS="$home/calls" \
    "$SWEEP" "$@" 2>&1
}

test_gone_endpoint_swept_and_live_kept() {
  local home fb out
  home=$(new_home gone-live); fb=$(make_tmux "$TMP_ROOT/gone-live")
  seed_markers "$home" firstmate_fm-gone
  seed_markers "$home" firstmate_fm-live
  world "$home" "fm-live" ok claude

  out=$(run_sweep "$fb" "$home")

  [ "$(count_markers "$home" firstmate_fm-gone)" -eq 0 ] \
    || fail "a positively missing window should lose every marker: $(ls -a "$home/state")"
  [ "$(count_markers "$home" firstmate_fm-live)" -eq 12 ] \
    || fail "a live window must keep every marker: $(ls -a "$home/state")"
  assert_contains "$out" "BOOTSTRAP_INFO: state residue sweep: removed 12 watcher record(s) for 1 gone endpoint(s)" \
    "the summary line should count what was removed"
  assert_contains "$out" "1 live" "the summary line should count the live endpoint that was kept"
  pass "sweep: a gone endpoint's markers are removed while a live endpoint's are kept"
}

test_live_without_record_never_queried_past_inventory() {
  local home fb out
  home=$(new_home live-only); fb=$(make_tmux "$TMP_ROOT/live-only")
  seed_markers "$home" firstmate_fm-live
  world "$home" "fm-live" ok claude

  out=$(run_sweep "$fb" "$home")

  [ -z "$out" ] || fail "nothing removed must print nothing, got: $out"
  [ "$(count_markers "$home" firstmate_fm-live)" -eq 12 ] || fail "a live endpoint lost markers"
  assert_not_contains "$(cat "$home/calls")" "pane_current_command" \
    "an endpoint present in the live inventory is settled by that inventory, not a per-window probe"
  pass "sweep: a live endpoint is kept from the inventory alone and the run stays silent"
}

test_ambiguous_and_unreadable_kept() {
  local home fb out
  home=$(new_home ambiguous); fb=$(make_tmux "$TMP_ROOT/ambiguous")
  seed_markers "$home" firstmate_fm-node
  # The window exists and its foreground is a node process the classifier
  # cannot attribute: ambiguous, never gone.
  world "$home" "fm-node" ok node
  out=$(run_sweep "$fb" "$home")
  [ -z "$out" ] || fail "an ambiguous endpoint must not be reported as removed: $out"
  [ "$(count_markers "$home" firstmate_fm-node)" -eq 12 ] || fail "an ambiguous endpoint lost markers"

  home=$(new_home unreadable); fb=$(make_tmux "$TMP_ROOT/unreadable")
  seed_markers "$home" firstmate_fm-gone
  world "$home" "" fail zsh
  out=$(run_sweep "$fb" "$home")
  [ -z "$out" ] || fail "an unreadable inventory must remove nothing: $out"
  [ "$(count_markers "$home" firstmate_fm-gone)" -eq 12 ] \
    || fail "an unreadable inventory must keep every marker: $(ls -a "$home/state")"
  pass "sweep: ambiguous and unreadable backend answers keep the markers"
}

test_meta_referenced_endpoint_never_touched() {
  local home fb out
  home=$(new_home meta); fb=$(make_tmux "$TMP_ROOT/meta")
  seed_markers "$home" firstmate_fm-held
  printf 'window=firstmate:fm-held\nkind=ship\nharness=claude\n' > "$home/state/held.meta"
  # The backend would call this window gone; the task record outranks it.
  world "$home" "" ok zsh

  out=$(run_sweep "$fb" "$home")

  [ -z "$out" ] || fail "a task-record endpoint must not be swept: $out"
  [ "$(count_markers "$home" firstmate_fm-held)" -eq 12 ] || fail "a task-record endpoint lost markers"
  assert_not_contains "$(cat "$home/calls")" "pane_current_command" \
    "a task-record endpoint must never be probed"
  pass "sweep: an endpoint named in a current task record is never queried or touched"
}

test_unmatched_key_kept() {
  local home fb out
  home=$(new_home unmatched); fb=$(make_tmux "$TMP_ROOT/unmatched")
  seed_markers "$home" default_wGJ_p2
  seed_markers "$home" remote_sm1
  seed_markers "$home" other_fm-x
  world "$home" "" ok zsh

  out=$(run_sweep "$fb" "$home")

  [ -z "$out" ] || fail "keys no candidate fits must remove nothing: $out"
  [ "$(count_markers "$home" default_wGJ_p2)" -eq 12 ] || fail "a herdr-shaped key lost markers in a tmux-only home"
  [ "$(count_markers "$home" remote_sm1)" -eq 12 ] || fail "a remote route key lost markers"
  [ "$(count_markers "$home" other_fm-x)" -eq 12 ] || fail "a key for an unknown session lost markers"
  pass "sweep: keys matching no candidate backend or session are left alone"
}

test_lossy_key_covered_by_live_window() {
  local home fb out
  home=$(new_home lossy); fb=$(make_tmux "$TMP_ROOT/lossy")
  # The live window fm-a.b and the key fm-a_b share one marker key; the
  # reconstructed target firstmate:fm-a_b is absent from the inventory, so a
  # sweep that trusted reconstruction alone would delete a live window's markers.
  seed_markers "$home" firstmate_fm-a_b
  world "$home" "fm-a.b" ok claude

  out=$(run_sweep "$fb" "$home")

  [ -z "$out" ] || fail "a key shared with a live window must not be swept: $out"
  [ "$(count_markers "$home" firstmate_fm-a_b)" -eq 12 ] || fail "the live window's shared key lost markers"
  pass "sweep: the lossy key derivation cannot retire a live window's markers"
}

test_scratch_rotation_by_age() {
  local home fb out now
  home=$(new_home scratch); fb=$(make_tmux "$TMP_ROOT/scratch")
  world "$home" "" ok zsh
  now=$(date +%s)
  printf 'old\n' > "$home/state/.claude-autoarm-output.OLD001"
  printf 'old\n' > "$home/state/.wake-rows.consume.OLD002"
  printf 'fresh\n' > "$home/state/.claude-autoarm-output.NEW001"
  printf 'fresh\n' > "$home/state/.wake-rows.consume.NEW002"
  printf 'edge\n' > "$home/state/.claude-autoarm-output.EDGE01"
  fm_touch_epoch $((now - 8 * 86400)) "$home/state/.claude-autoarm-output.OLD001" "$home/state/.wake-rows.consume.OLD002"
  fm_touch_epoch $((now - 6 * 86400)) "$home/state/.claude-autoarm-output.EDGE01"

  out=$(run_sweep "$fb" "$home")

  [ ! -e "$home/state/.claude-autoarm-output.OLD001" ] || fail "an 8-day-old auto-arm capture should rotate"
  [ ! -e "$home/state/.wake-rows.consume.OLD002" ] || fail "an 8-day-old drain staging file should rotate"
  [ -e "$home/state/.claude-autoarm-output.NEW001" ] || fail "a fresh auto-arm capture must survive"
  [ -e "$home/state/.wake-rows.consume.NEW002" ] || fail "a fresh drain staging file must survive"
  [ -e "$home/state/.claude-autoarm-output.EDGE01" ] || fail "a 6-day-old capture is inside the 7-day window and must survive"
  assert_contains "$out" "0 gone endpoint(s) and 2 stale scratch file(s)" \
    "the summary line should count the rotated scratch files"
  pass "sweep: scratch files rotate only past the documented age"
}

test_dry_run_reports_and_removes_nothing() {
  local home fb out now
  home=$(new_home dry); fb=$(make_tmux "$TMP_ROOT/dry")
  seed_markers "$home" firstmate_fm-gone
  world "$home" "" ok zsh
  now=$(date +%s)
  printf 'old\n' > "$home/state/.claude-autoarm-output.OLD001"
  fm_touch_epoch $((now - 30 * 86400)) "$home/state/.claude-autoarm-output.OLD001"

  out=$(run_sweep "$fb" "$home" --dry-run)

  assert_contains "$out" "would retire 12 record(s) for tmux endpoint firstmate:fm-gone (missing)" \
    "dry run should name the endpoint it would retire"
  assert_contains "$out" "would rotate .claude-autoarm-output.OLD001" "dry run should name the scratch file it would rotate"
  assert_contains "$out" "BOOTSTRAP_INFO: state residue sweep: would remove 12 watcher record(s) for 1 gone endpoint(s) and 1 stale scratch file(s)" \
    "dry run should print the would-remove summary"
  [ "$(count_markers "$home" firstmate_fm-gone)" -eq 12 ] || fail "dry run removed markers"
  [ -e "$home/state/.claude-autoarm-output.OLD001" ] || fail "dry run removed a scratch file"

  out=$(run_sweep "$fb" "$home" --bogus)
  assert_contains "$out" "usage: fm-state-residue-sweep.sh [--dry-run]" "an unknown flag should print usage"
  pass "sweep: --dry-run reports every verdict and removes nothing"
}

test_only_marker_family_files_are_touched() {
  local home fb out
  home=$(new_home family); fb=$(make_tmux "$TMP_ROOT/family")
  seed_markers "$home" firstmate_fm-gone
  # Task-keyed and unrelated dotfiles that share a key-looking suffix stay.
  printf 'x' > "$home/state/.seen-firstmate_fm-gone"
  printf 'x' > "$home/state/.hb-surfaced-firstmate_fm-gone"
  printf 'x' > "$home/state/.subsuper-stale-firstmate_fm-gone"
  printf 'x' > "$home/state/.last-watcher-beat"
  printf 'x' > "$home/state/gone.status"
  world "$home" "" ok zsh

  out=$(run_sweep "$fb" "$home")

  assert_contains "$out" "removed 12 watcher record(s) for 1 gone endpoint(s)" "the endpoint should be swept"
  for f in .seen-firstmate_fm-gone .hb-surfaced-firstmate_fm-gone .subsuper-stale-firstmate_fm-gone .last-watcher-beat gone.status; do
    [ -e "$home/state/$f" ] || fail "$f is outside the per-endpoint family and must survive"
  done
  pass "sweep: only the twelve per-endpoint marker files are ever removed"
}

test_query_budget_defers_the_remainder() {
  local home fb out i
  home=$(new_home budget); fb=$(make_tmux "$TMP_ROOT/budget")
  # 202 gone windows against the documented 200-question budget: only .hash-
  # markers, so the removed-record count equals the endpoint count.
  i=0
  while [ "$i" -lt 202 ]; do
    printf 'x' > "$home/state/.hash-firstmate_fm-gone$i"
    i=$((i + 1))
  done
  world "$home" "" ok zsh

  out=$(run_sweep "$fb" "$home")

  assert_contains "$out" "removed 200 watcher record(s) for 200 gone endpoint(s)" "the budget bounds one run's questions: $out"
  assert_contains "$out" "2 deferred to the next session start" "the remainder should be reported as deferred: $out"
  [ "$(find "$home/state" -name '.hash-firstmate_fm-gone*' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "exactly the deferred keys should remain"

  out=$(run_sweep "$fb" "$home")
  assert_contains "$out" "removed 2 watcher record(s) for 2 gone endpoint(s)" "the next run should finish the remainder: $out"
  assert_not_contains "$out" "deferred" "nothing should be deferred once under budget"
  pass "sweep: the per-run question budget defers the remainder to the next run"
}

# --- herdr candidate ---------------------------------------------------------

# make_herdr <dir>: a herdr CLI stub driven by the fixture file
# FM_TEST_HERDR_WORLD:
#   server=running|stopped|garbled   `status --json` and whether `api snapshot` answers
#   panes=<space-separated pane ids>   live panes in the session
#   fg=<process name>        the foreground process of every live pane
make_herdr() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
world=${FM_TEST_HERDR_WORLD:?}
val() { sed -n "s/^$1=//p" "$world" | tail -1; }
printf '%s\n' "$*" >> "${FM_TEST_HERDR_CALLS:?}"
running=$(val server)
case "${1:-} ${2:-}" in
  "status --json")
    case "$running" in
      running) printf '%s\n' '{"server":{"running":true}}' ;;
      stopped) printf '%s\n' '{"server":{"running":false}}' ;;
      *) printf '%s\n' 'not json at all' ;;
    esac
    exit 0 ;;
  "api snapshot")
    case "$running" in
      running) ;;
      stopped) printf '%s\n' '{"error":{"code":"server_not_running"}}' >&2; exit 1 ;;
      *) printf '%s\n' 'garbled'; exit 0 ;;
    esac
    printf '{"result":{"snapshot":{"panes":['
    first=1
    for p in $(val panes); do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"pane_id":"%s","tab_id":"%s:t1","workspace_id":"%s"}' "$p" "${p%%:*}" "${p%%:*}"
    done
    printf ']}}}\n'
    exit 0 ;;
  "pane get")
    [ "$running" = running ] || { printf '%s\n' '{"error":{"code":"server_not_running"}}' >&2; exit 1; }
    for p in $(val panes); do
      [ "$p" = "${3:-}" ] || continue
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s:t1","workspace_id":"%s"}}}\n' "$p" "${p%%:*}" "${p%%:*}"
      exit 0
    done
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    exit 1 ;;
  "agent get")
    printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    exit 0 ;;
  "pane process-info")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"%s","argv0":"%s","argv":["%s"]}]}}}\n' \
      "${4:-}" "$(val fg)" "$(val fg)" "$(val fg)"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

herdr_world() {  # <home> <server> <panes> <fg>
  local home=$1
  {
    printf 'server=%s\n' "$2"
    printf 'panes=%s\n' "$3"
    printf 'fg=%s\n' "$4"
  } > "$home/herdr-world"
}

run_sweep_herdr() {  # <fakebin> <home> [args...]
  local fb=$1 home=$2
  shift 2
  PATH="$fb:$BASE_PATH" TMUX='' HERDR_ENV='' HERDR_SESSION='' FM_HOME="$home" \
    FM_TEST_HERDR_WORLD="$home/herdr-world" FM_TEST_HERDR_CALLS="$home/herdr-calls" \
    FM_TEST_TMUX_WORLD="$home/world" FM_TEST_TMUX_CALLS="$home/calls" \
    "$SWEEP" "$@" 2>&1
}

test_herdr_gone_pane_swept_live_and_stopped_server_handled() {
  local home fb out
  command -v jq >/dev/null 2>&1 || { pass "sweep (herdr): skipped - jq not installed"; return 0; }
  home=$(new_home herdr); fb=$(make_herdr "$TMP_ROOT/herdr")
  printf 'herdr\n' > "$home/config/backend"
  seed_markers "$home" default_w1H_p2
  seed_markers "$home" default_wGJ_p2
  seed_markers "$home" default_wGJ_p9
  herdr_world "$home" running "wGJ:p2" claude

  out=$(run_sweep_herdr "$fb" "$home")

  [ "$(count_markers "$home" default_w1H_p2)" -eq 0 ] \
    || fail "a pane the server reports pane_not_found should lose its markers: $out"
  [ "$(count_markers "$home" default_wGJ_p9)" -eq 0 ] \
    || fail "a second gone pane in the same workspace should lose its markers: $out"
  [ "$(count_markers "$home" default_wGJ_p2)" -eq 12 ] || fail "a live herdr pane lost markers: $out"
  assert_contains "$out" "removed 24 watcher record(s) for 2 gone endpoint(s)" "the summary should count both gone panes: $out"
  assert_contains "$out" "1 live" "the live pane should be counted as kept"
  [ "$(grep -c '^pane get' "$home/herdr-calls")" -eq 2 ] \
    || fail "each unresolved pane should be asked exactly once; got: $(cat "$home/herdr-calls")"

  # A positively stopped server is authoritative absence for every pane.
  home=$(new_home herdr-stopped); fb=$(make_herdr "$TMP_ROOT/herdr-stopped")
  printf 'herdr\n' > "$home/config/backend"
  seed_markers "$home" default_w1H_p2
  herdr_world "$home" stopped "" claude
  out=$(run_sweep_herdr "$fb" "$home")
  [ "$(count_markers "$home" default_w1H_p2)" -eq 0 ] \
    || fail "a stopped session server should retire its panes' markers: $out"

  # A running server whose snapshot cannot be parsed certifies nothing.
  home=$(new_home herdr-unreadable); fb=$(make_herdr "$TMP_ROOT/herdr-unreadable")
  printf 'herdr\n' > "$home/config/backend"
  seed_markers "$home" default_w1H_p2
  herdr_world "$home" garbled "" claude
  out=$(run_sweep_herdr "$fb" "$home")
  [ -z "$out" ] || fail "an unreadable herdr inventory must remove nothing: $out"
  [ "$(count_markers "$home" default_w1H_p2)" -eq 12 ] || fail "an unreadable herdr inventory removed markers"
  pass "sweep (herdr): gone panes and a stopped server retire markers; live and unreadable keep them"
}

# --- bootstrap seat -----------------------------------------------------------

# make_toolchain <dir>: the stubs bin/fm-bootstrap.sh's read-only diagnostics
# need to stay quiet, minus tmux (the case adds its own controllable one).
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' '0.1.29'
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then printf '%s\n' 'Usage: treehouse get [--lease]'; fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' '0.1.29'
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/treehouse" "$fakebin/no-mistakes" "$fakebin/tasks-axi" "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {  # <fakebin> <home> [extra env...]
  local fb=$1 home=$2
  shift 2
  PATH="$fb:$BASE_PATH" TMUX='' HERDR_ENV='' FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip \
    FM_TEST_TMUX_WORLD="$home/world" FM_TEST_TMUX_CALLS="$home/calls" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_bootstrap_runs_sweep_only_when_locked() {
  local home fb tmuxfb out
  home=$(new_home boot); fb=$(make_toolchain "$TMP_ROOT/boot"); tmuxfb=$(make_tmux "$TMP_ROOT/boot")
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  seed_markers "$home" firstmate_fm-gone
  world "$home" "" ok zsh

  out=$(run_bootstrap "$tmuxfb:$fb" "$home" FM_BOOTSTRAP_DETECT_ONLY=1)
  assert_not_contains "$out" "state residue sweep" "the read-only session path must not report a sweep"
  [ "$(count_markers "$home" firstmate_fm-gone)" -eq 12 ] \
    || fail "the read-only session path removed markers: $out"

  out=$(run_bootstrap "$tmuxfb:$fb" "$home")
  assert_contains "$out" "BOOTSTRAP_INFO: state residue sweep: removed 12 watcher record(s) for 1 gone endpoint(s)" \
    "the locked local pass should run the sweep and relay its summary: $out"
  [ "$(count_markers "$home" firstmate_fm-gone)" -eq 0 ] || fail "the locked pass left markers behind"

  out=$(run_bootstrap "$tmuxfb:$fb" "$home")
  assert_not_contains "$out" "state residue sweep" "a converged home must stay silent on the next run: $out"
  pass "bootstrap: the sweep runs on the locked local pass only and converges silently"
}

test_gone_endpoint_swept_and_live_kept
test_live_without_record_never_queried_past_inventory
test_ambiguous_and_unreadable_kept
test_meta_referenced_endpoint_never_touched
test_unmatched_key_kept
test_lossy_key_covered_by_live_window
test_scratch_rotation_by_age
test_dry_run_reports_and_removes_nothing
test_only_marker_family_files_are_touched
test_query_budget_defers_the_remainder
test_herdr_gone_pane_swept_live_and_stopped_server_handled
test_bootstrap_runs_sweep_only_when_locked

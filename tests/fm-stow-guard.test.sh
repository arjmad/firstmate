#!/usr/bin/env bash
# Behavior tests for the opt-in Claude Stop hook that asks a primary to /stow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-stow-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-guard)
PRIMARY="$TMP_ROOT/primary"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$PRIMARY/state"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" config user.name fixture
git -C "$PRIMARY" config user.email fixture@example.test
git -C "$PRIMARY" config commit.gpgsign false

# invoke_guard <root> <state> <config> [env assignments...]
# The hook payload is on stdin. Prints nothing. The exit status is the hook's.
invoke_guard() {
  local root=$1 state=$2 config=$3
  shift 3
  : > "$OUT"
  : > "$ERR"
  env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    "$@" \
    "$GUARD" >"$OUT" 2>"$ERR"
}

prepare_case() {
  CASE_STATE="$TMP_ROOT/cases/$1/state"
  CASE_CONFIG="$TMP_ROOT/cases/$1/config"
  CASE_TRANSCRIPT="$TMP_ROOT/cases/$1/transcript.jsonl"
  mkdir -p "$CASE_STATE" "$CASE_CONFIG"
  : > "$CASE_TRANSCRIPT"
}

payload() {
  local active=${1:-false}
  printf '{"session_id":"s1","stop_hook_active":%s,"transcript_path":"%s"}\n' \
    "$active" "$CASE_TRANSCRIPT"
}

write_usage() {
  jq -nc --argjson tokens "$1" \
    '{message:{usage:{input_tokens:$tokens,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    >> "$CASE_TRANSCRIPT"
}

assert_silent() {
  local label=$1
  [ ! -s "$OUT" ] || fail "$label wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

assert_block() {
  local label=$1 needle=$2
  jq -e --arg needle "$needle" \
    '.decision == "block" and (.reason | contains($needle))' "$OUT" >/dev/null 2>&1 \
    || fail "$label did not block with '$needle': $(cat "$OUT") $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

test_absent_config_is_silent() {
  local rc=0
  prepare_case absent
  write_usage 900000
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "absent config must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "absent config"
  [ ! -e "$CASE_STATE/.stow-guard.json" ] || fail "absent config wrote trigger state"
  pass "absent config/stow-guard leaves the stop unchanged and writes no state"
}

test_context_crossing_blocks_once_until_rearm() {
  local rc=0
  prepare_case context
  printf '%s\n' '# note' 'tokens=nope' 'tokens=0' 'tokens=1000' > "$CASE_CONFIG/stow-guard"
  write_usage 100
  write_usage 1000
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "context crossing must exit 0, got $rc"
  assert_block "context crossing" "context is 1000 tokens"
  jq -e '.fired.s1 == true and (.last_stow | not)' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "context crossing did not record the session as asked: $(cat "$CASE_STATE/.stow-guard.json")"

  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "second crossing must exit 0, got $rc"
  assert_silent "second crossing of the same context"

  : > "$CASE_TRANSCRIPT"
  write_usage 100
  rc=0
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "continuation re-arm must exit 0, got $rc"
  assert_silent "continuation below two-thirds"
  jq -e '.fired | has("s1") | not' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "continuation below two-thirds left the session armed: $(cat "$CASE_STATE/.stow-guard.json")"

  : > "$CASE_TRANSCRIPT"
  write_usage 1000
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "re-armed crossing must exit 0, got $rc"
  assert_block "re-armed crossing" "context is 1000 tokens"
  pass "a context crossing blocks once, a continuation below two-thirds re-arms, and the next crossing blocks"
}

test_guard_ask_never_offers_a_restart() {
  local rc=0
  prepare_case guard-ask
  printf 'tokens=1000\nrestart=1\n' > "$CASE_CONFIG/stow-guard"
  write_usage 1200
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    TMUX_PANE=%7 HERDR_ENV= || rc=$?
  [ "$rc" -eq 0 ] || fail "the guard's ask with restart=1 must exit 0, got $rc"
  assert_block "the guard's ask with restart=1" "with the argument quick (/stow quick) for a quick save, then continue the turn you were in."
  ! grep -q 'fm-helm-refresh' "$OUT" || fail "the guard's ask offered a restart: $(cat "$OUT")"
  jq -e 'has("offer") | not' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "the guard's ask recorded an offer: $(cat "$CASE_STATE/.stow-guard.json")"

  # A typed /stow's offer already in the state file passes through unchanged.
  prepare_case guard-ask-existing-offer
  printf 'tokens=1000\nrestart=1\n' > "$CASE_CONFIG/stow-guard"
  printf '{"asked":0,"fired":{},"offer":{"sid":"s1","at":4000}}\n' > "$CASE_STATE/.stow-guard.json"
  write_usage 1200
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" TMUX_PANE=%7 HERDR_ENV= || rc=$?
  [ "$rc" -eq 0 ] || fail "an ask with an existing offer must exit 0, got $rc"
  assert_block "an ask with an existing offer" "then continue the turn you were in."
  jq -e '.offer == {sid:"s1", at:4000}' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "the guard's ask changed an existing offer: $(cat "$CASE_STATE/.stow-guard.json")"

  prepare_case guard-ask-herdr
  printf 'tokens=1000\nrestart=1\n' > "$CASE_CONFIG/stow-guard"
  write_usage 1200
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    TMUX_PANE= HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION= || rc=$?
  [ "$rc" -eq 0 ] || fail "the guard's ask in a Herdr pane must exit 0, got $rc"
  assert_block "the guard's ask in a Herdr pane" "then continue the turn you were in."
  jq -e 'has("offer") | not' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "the guard's ask in a Herdr pane recorded an offer: $(cat "$CASE_STATE/.stow-guard.json")"
  pass "with restart=1 in a pane, the guard's ask names no refresh request, records no offer, and carries an existing offer through unchanged"
}

PROMPT_SID=11111111-2222-3333-4444-555555555555
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# prepare_prompt_case <name>: an opted-in home whose lock session is PROMPT_SID.
prepare_prompt_case() {
  prepare_case "$1"
  printf 'tokens=1000\nrestart=1\n' > "$CASE_CONFIG/stow-guard"
  printf '%s\n' "$PROMPT_SID" > "$CASE_STATE/.lock-session"
}

prompt_payload() {  # <prompt> [<session id>]
  jq -nc --arg p "$1" --arg sid "${2-$PROMPT_SID}" \
    '{hook_event_name:"UserPromptSubmit", prompt:$p} + (if $sid == "" then {} else {session_id:$sid} end)'
}

# invoke_prompt <root> <payload> [env assignments...]
# Runs `fm-stow-guard.sh prompt` as the lock-owning session: a bash named
# claude records its own pid in state/.lock, then runs the hook as its child
# inside a pretend tmux pane unless the caller passes TMUX_PANE=.
invoke_prompt() {
  local root=$1 body=$2 rc=0
  shift 2
  : > "$OUT"
  : > "$ERR"
  # shellcheck disable=SC2016 # the session script expands its own arguments.
  env -u GROK_AGENT -u GROK_HOOK_EVENT -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u TMUX \
    TMUX_PANE=%7 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" FM_STOW_GUARD_NOW=5000 \
    "$@" \
    "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$1/.lock"; printf "%s" "$2" | "$3" prompt >"$4" 2>"$5"; exit $?' _ \
    "$CASE_STATE" "$body" "$GUARD" "$OUT" "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "the prompt hook must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "the prompt hook"
}

assert_no_offer() {  # <label>
  if [ -f "$CASE_STATE/.stow-guard.json" ]; then
    jq -e 'has("offer") | not' "$CASE_STATE/.stow-guard.json" >/dev/null \
      || fail "$1 recorded an offer: $(cat "$CASE_STATE/.stow-guard.json")"
  fi
}

test_typed_stow_records_the_offer() {
  local rc=0
  prepare_prompt_case typed-stow
  printf '{"last_stow":100,"asked":5,"fired":{"other":true}}\n' > "$CASE_STATE/.stow-guard.json"
  invoke_prompt "$PRIMARY" "$(prompt_payload /stow)"
  jq -e --arg sid "$PROMPT_SID" \
    '.offer == {sid:$sid, at:5000} and .last_stow == 100 and .asked == 5 and .fired == {other:true}' \
    "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a typed /stow did not record only the offer: $(cat "$CASE_STATE/.stow-guard.json")"

  # The guard's own ask state is untouched, so a Stop over the line still asks,
  # and it carries the offer through for the request after the pass.
  write_usage 1200
  rc=0
  printf '{"session_id":"%s","transcript_path":"%s"}\n' "$PROMPT_SID" "$CASE_TRANSCRIPT" \
    | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW=5001 TMUX_PANE=%7 || rc=$?
  [ "$rc" -eq 0 ] || fail "the Stop after a typed /stow must exit 0, got $rc"
  assert_block "the Stop over the line after a typed /stow" "context is 1200 tokens"
  jq -e --arg sid "$PROMPT_SID" '.offer == {sid:$sid, at:5000}' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "the Stop dropped the typed /stow's offer: $(cat "$CASE_STATE/.stow-guard.json")"

  prepare_prompt_case typed-stow-args
  invoke_prompt "$PRIMARY" "$(prompt_payload $'  /stow  quickly\n')" \
    TMUX_PANE= HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  jq -e --arg sid "$PROMPT_SID" '.offer == {sid:$sid, at:5000}' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a typed /stow with arguments in a Herdr pane recorded no offer: $(cat "$CASE_STATE/.stow-guard.json" 2>/dev/null)"
  pass "a /stow the lock session types records only the restart offer, and the guard's next ask carries it through"
}

test_typed_stow_quick_records_no_offer() {
  local prompt n=0
  local -a prompts=('/stow quick' $'  /stow\tquick  \n' '/stow quick extra words' $'/stow\nquick' '/stow QUICK')
  for prompt in "${prompts[@]}"; do
    n=$((n + 1))
    prepare_prompt_case "typed-stow-quick-$n"
    invoke_prompt "$PRIMARY" "$(prompt_payload "$prompt")"
    assert_no_offer "typed quick prompt $n"
  done
  pass "a typed /stow quick records no restart offer"
}

test_fleet_sent_stow_records_no_offer() {
  local prompt label mark=$'\xE2\x81\xA3' n=0
  local -a prompts=(
    "[fm-from-firstmate]${mark}/stow"
    "[fm-from-firstmate]/stow"
    "${mark}FIRSTMATE_OP: v1 watcher: /stow"
    ": Firstmate operational input waiting: read '/home/x/state/operational-inbox/1-a.msg' and handle its contents as Firstmate operational input."
    $'\n<task-notification>\n/stow\n</task-notification>'
    "please run /stow now"
    "/stowaway"
    "/stow-cascade"
  )
  for prompt in "${prompts[@]}"; do
    n=$((n + 1))
    prepare_prompt_case "fleet-stow-$n"
    invoke_prompt "$PRIMARY" "$(prompt_payload "$prompt")"
    label="prompt $n ($(printf '%s' "$prompt" | head -c 40))"
    assert_no_offer "$label"
  done
  pass "a marked, doorbell, rewake, or other non-/stow prompt records no offer"
}

test_typed_stow_outside_the_primary_session_records_no_offer() {
  local rc=0 child="$TMP_ROOT/prompt-child" second="$TMP_ROOT/prompt-second"

  prepare_prompt_case prompt-no-restart
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  invoke_prompt "$PRIMARY" "$(prompt_payload /stow)"
  assert_no_offer "a home without restart=1"

  prepare_prompt_case prompt-other-session
  invoke_prompt "$PRIMARY" "$(prompt_payload /stow other-session)"
  assert_no_offer "a session other than the lock session"

  prepare_prompt_case prompt-no-sid
  invoke_prompt "$PRIMARY" "$(prompt_payload /stow '')"
  assert_no_offer "a payload with no session id"

  prepare_prompt_case prompt-no-pane
  invoke_prompt "$PRIMARY" "$(prompt_payload /stow)" TMUX_PANE=
  assert_no_offer "a session outside any pane"

  # The lock names this test's own shell, which is no harness ancestor.
  prepare_prompt_case prompt-not-owner
  printf '%s\n' "$$" > "$CASE_STATE/.lock"
  prompt_payload /stow | env -u GROK_AGENT -u GROK_HOOK_EVENT -u TMUX TMUX_PANE=%7 \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$GUARD" prompt >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a session without the lock must exit 0, got $rc"
  assert_silent "a session without the lock"
  assert_no_offer "a session without the lock"

  # Its own primary, so the other fixtures' commits and branches stay theirs.
  mkdir -p "$TMP_ROOT/prompt-primary"
  git -C "$TMP_ROOT/prompt-primary" init -q
  printf '# fixture\n' > "$TMP_ROOT/prompt-primary/AGENTS.md"
  git -C "$TMP_ROOT/prompt-primary" add AGENTS.md
  git -C "$TMP_ROOT/prompt-primary" -c user.name=fixture -c user.email=fixture@example.test \
    -c commit.gpgsign=false commit -qm fixture
  git -C "$TMP_ROOT/prompt-primary" worktree add -q -b fixture-prompt-child "$child"
  mkdir -p "$child/bin"
  prepare_prompt_case prompt-crew
  invoke_prompt "$child" "$(prompt_payload /stow)"
  assert_no_offer "a crew worktree"

  mkdir -p "$second/bin"
  git -C "$second" init -q
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  prepare_prompt_case prompt-secondmate
  invoke_prompt "$second" "$(prompt_payload /stow)"
  assert_no_offer "a secondmate home"
  pass "a typed /stow records no offer without restart=1, the lock session's id, a pane, or the lock, nor in a crew worktree or secondmate home"
}

test_continuation_stop_blocks_once_per_crossing() {
  local rc=0
  prepare_case continuation
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  write_usage 1200
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "continuation crossing must exit 0, got $rc"
  assert_block "continuation crossing" "context is 1200 tokens"

  write_usage 1300
  rc=0
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "second continuation above the line must exit 0, got $rc"
  assert_silent "second continuation above the line"
  pass "a continuation stop at the token line blocks once and the next continuation above it does not"
}

test_age_interval_blocks_once_per_hour() {
  local rc=0 now=1700000000 later soon again
  prepare_case age
  : > "$CASE_CONFIG/stow-guard"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "first opt-in stop must exit 0, got $rc"
  assert_silent "first opt-in stop"
  jq -e --argjson now "$now" '.last_stow == $now and .asked == 0' \
    "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "first opt-in stop did not start the age clock: $(cat "$CASE_STATE/.stow-guard.json")"

  later=$((now + 86400))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$later" || rc=$?
  [ "$rc" -eq 0 ] || fail "age ask must exit 0, got $rc"
  assert_block "age ask" "older than 24h"

  soon=$((later + 10))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$soon" || rc=$?
  [ "$rc" -eq 0 ] || fail "age cooldown must exit 0, got $rc"
  assert_silent "age ask inside the hour cooldown"

  again=$((later + 3600))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$again" || rc=$?
  [ "$rc" -eq 0 ] || fail "age ask after the cooldown must exit 0, got $rc"
  assert_block "age ask after the cooldown" "older than 24h"
  pass "the age ask starts the clock, blocks once a day, and waits an hour before asking again"
}

test_recorded_stow_sets_the_age_clock() {
  local rc=0 epoch now
  command -v python3 >/dev/null 2>&1 || {
    pass "recorded /stow sets the age clock (skipped, python3 not found)"
    return
  }
  prepare_case stow
  : > "$CASE_CONFIG/stow-guard"
  epoch=$(python3 -c 'import datetime; print(int(datetime.datetime.fromisoformat("2026-01-01T00:00:00+00:00").timestamp()))')
  jq -nc \
    '{timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",name:"Skill",input:{skill:"stow"}}],usage:{input_tokens:10,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    > "$CASE_TRANSCRIPT"
  now=$((epoch + 100))
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "recent /stow stop must exit 0, got $rc"
  assert_silent "recent /stow"
  jq -e --argjson epoch "$epoch" '.last_stow == $epoch' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "recent /stow was not recorded: $(cat "$CASE_STATE/.stow-guard.json")"

  : > "$CASE_TRANSCRIPT"
  now=$((epoch + 200))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "tail without the /stow must exit 0, got $rc"
  assert_silent "tail that no longer contains the /stow"
  jq -e --argjson epoch "$epoch" '.last_stow == $epoch' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a later tail rewound the /stow clock: $(cat "$CASE_STATE/.stow-guard.json")"

  now=$((epoch + 86400 + 100))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "aged remembered /stow must exit 0, got $rc"
  assert_block "aged remembered /stow" "older than 24h"
  pass "a Skill /stow sets the age clock and a later tail does not rewind it"
}

# write_stow <iso timestamp> [<args>]: append a stow Skill call, with args only
# when given, so a call with no args stays the shape Claude Code writes.
write_stow() {
  jq -nc --arg ts "$1" --arg args "${2-}" --argjson has_args "$([ $# -ge 2 ] && echo true || echo false)" \
    '{timestamp:$ts,message:{content:[{type:"tool_use",name:"Skill",input:({skill:"stow"} + (if $has_args then {args:$args} else {} end))}],usage:{input_tokens:10,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    >> "$CASE_TRANSCRIPT"
}

iso_epoch() {
  python3 -c 'import datetime, sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$1"
}

test_each_ask_names_its_pass() {
  local rc=0 now=1700000000
  prepare_case ask-context
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  write_usage 1200
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "the context ask must exit 0, got $rc"
  assert_block "the context ask" "Run the stow skill now with the argument quick (/stow quick) for a quick save"
  ! grep -q 'full pass' "$OUT" || fail "the context ask asked for the full pass: $(cat "$OUT")"

  prepare_case ask-age
  : > "$CASE_CONFIG/stow-guard"
  printf '{"last_stow":%s,"asked":0,"fired":{}}\n' "$((now - 86400))" > "$CASE_STATE/.stow-guard.json"
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "the age ask must exit 0, got $rc"
  assert_block "the age ask" "Run the /stow skill now (full pass, no argument)"
  ! grep -q 'quick' "$OUT" || fail "the age ask asked for a quick save: $(cat "$OUT")"
  pass "the context ask asks for /stow quick and the age ask asks for the full pass"
}

test_quick_save_does_not_move_the_full_pass_clock() {
  local rc=0 full quick now
  command -v python3 >/dev/null 2>&1 || {
    pass "a quick save does not move the full pass clock (skipped, python3 not found)"
    return
  }
  prepare_case quick-clock
  : > "$CASE_CONFIG/stow-guard"
  full=$(iso_epoch 2026-01-01T00:00:00Z)
  quick=$(iso_epoch 2026-01-01T06:00:00Z)
  write_stow 2026-01-01T00:00:00Z
  write_stow 2026-01-01T06:00:00Z quick
  now=$((quick + 100))
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "a tail with a full and a newer quick save must exit 0, got $rc"
  assert_silent "a tail with a full and a newer quick save"
  jq -e --argjson full "$full" '.last_stow == $full' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a newer quick save moved the clock past the full pass: $(cat "$CASE_STATE/.stow-guard.json")"

  # Only quick saves after it, each spelled another way: the age ask still comes due.
  : > "$CASE_TRANSCRIPT"
  write_stow 2026-01-01T12:00:00Z ' Quick'
  write_stow 2026-01-01T18:00:00Z $'quick\tat the token line'
  write_stow 2026-01-01T23:00:00Z QUICK
  now=$((full + 86400))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "a quick-only tail a day after the full pass must exit 0, got $rc"
  assert_block "a quick-only tail a day after the full pass" "Run the /stow skill now (full pass, no argument)"
  jq -e --argjson full "$full" '.last_stow == $full' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "quick saves moved the clock: $(cat "$CASE_STATE/.stow-guard.json")"

  # A stow call with other args, or a word that only starts with quick, is a full pass.
  : > "$CASE_TRANSCRIPT"
  write_stow 2026-01-02T01:00:00Z 'quickly please'
  now=$(($(iso_epoch 2026-01-02T01:00:00Z) + 100))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "a stow call with other args must exit 0, got $rc"
  assert_silent "a stow call with other args"
  jq -e --argjson stamp "$(iso_epoch 2026-01-02T01:00:00Z)" '.last_stow == $stamp' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a stow call with other args did not move the clock: $(cat "$CASE_STATE/.stow-guard.json")"

  # On the first opt-in stop, a quick-only tail starts the clock at now, as an empty tail does.
  prepare_case quick-first
  : > "$CASE_CONFIG/stow-guard"
  write_stow 2026-01-01T06:00:00Z quick
  now=$((quick + 100))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "a first stop with only a quick save must exit 0, got $rc"
  assert_silent "a first stop with only a quick save"
  jq -e --argjson now "$now" '.last_stow == $now' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a quick-only first stop did not start the clock at now: $(cat "$CASE_STATE/.stow-guard.json")"
  pass "a quick save leaves last_stow on the newest full pass, the age ask still comes due, and other args count as a full pass"
}

test_both_asks_due_asks_quick_then_full_below_the_line() {
  local rc=0 now=1700000000
  prepare_case both-due
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  printf '{"last_stow":%s,"asked":0,"fired":{}}\n' "$((now - 2 * 86400))" > "$CASE_STATE/.stow-guard.json"
  write_usage 1200
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "a stop with both asks due must exit 0, got $rc"
  assert_block "a stop with both asks due" "(/stow quick) for a quick save"

  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$((now + 60))" || rc=$?
  [ "$rc" -eq 0 ] || fail "the next stop inside the hour must exit 0, got $rc"
  assert_silent "the next stop inside the hour"

  # An hour later the context is still over the line, so the full pass waits.
  write_usage 1300
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$((now + 3600))" || rc=$?
  [ "$rc" -eq 0 ] || fail "the stop an hour later over the line must exit 0, got $rc"
  assert_silent "the stop an hour later over the line"

  # After a compaction drops the context below the line, the full pass is asked for.
  : > "$CASE_TRANSCRIPT"
  write_usage 500
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" FM_STOW_GUARD_NOW="$((now + 3700))" || rc=$?
  [ "$rc" -eq 0 ] || fail "the stop below the line must exit 0, got $rc"
  assert_block "the stop below the line" "Run the /stow skill now (full pass, no argument)"
  pass "with both asks due the context ask asks for a quick save, and the age ask waits until the context is below the line"
}

test_crew_worktree_is_silent() {
  local child="$TMP_ROOT/child" rc=0
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  prepare_case crew
  mkdir -p "$child/bin" "$child/state" "$child/config"
  printf 'tokens=1000\n' > "$child/config/stow-guard"
  write_usage 900000
  payload | invoke_guard "$child" "$child/state" "$child/config" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crew worktree must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "crew worktree"
  [ ! -e "$child/state/.stow-guard.json" ] || fail "a crew worktree wrote trigger state"
  pass "a linked crew worktree stays silent even when the opt-in file and a high reading are present"
}

test_secondmate_home_is_silent() {
  local second="$TMP_ROOT/second" rc=0
  if ! git -C "$PRIMARY" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$PRIMARY" add AGENTS.md
    git -C "$PRIMARY" commit -qm fixture
  fi
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state" "$second/config"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  printf 'tokens=1000\n' > "$second/config/stow-guard"
  prepare_case secondmate
  write_usage 900000
  payload | invoke_guard "$second" "$second/state" "$second/config" || rc=$?
  [ "$rc" -eq 0 ] || fail "a secondmate home must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "secondmate home"
  [ ! -e "$second/state/.stow-guard.json" ] || fail "a secondmate home wrote trigger state"
  pass "a marked secondmate home stays silent even when the opt-in file and a high reading are present"
}

test_missing_python_skips_the_age_ask() {
  local rc=0 fakebin="$TMP_ROOT/no-python-bin" tool bin epoch now
  command -v python3 >/dev/null 2>&1 || {
    pass "missing python3 skips the age ask (skipped, python3 not found)"
    return
  }
  prepare_case nopython
  : > "$CASE_CONFIG/stow-guard"
  epoch=$(python3 -c 'import datetime; print(int(datetime.datetime.fromisoformat("2026-01-01T00:00:00+00:00").timestamp()))')
  jq -nc \
    '{timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",name:"Skill",input:{skill:"stow"}}],usage:{input_tokens:10,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    > "$CASE_TRANSCRIPT"
  jq -n --argjson last_stow "$((epoch - 100000))" --argjson asked 0 --argjson fired '{}' \
    '{last_stow:$last_stow, asked:$asked, fired:$fired}' > "$CASE_STATE/.stow-guard.json"
  mkdir -p "$fakebin"
  for tool in bash cat dirname tail awk git jq date mktemp mv rm; do
    bin=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$bin" ] || fail "test needs $tool on PATH"
    ln -sf "$bin" "$fakebin/$tool"
  done
  PATH="$fakebin" command -v python3 >/dev/null 2>&1 && fail "fixture PATH still finds python3"
  now=$((epoch + 100))
  payload | env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing python3 age stop must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "missing python3 with a recent /stow and a stale clock"

  : > "$CASE_TRANSCRIPT"
  write_usage 400000
  rc=0
  payload | env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing python3 context stop must exit 0, got $rc: $(cat "$ERR")"
  assert_block "missing python3 context crossing" "context is 400000 tokens"
  pass "missing python3 skips the age ask and still asks on a context crossing"
}

test_bad_payloads_and_missing_jq_are_silent() {
  local rc=0 fakebin="$TMP_ROOT/no-jq-bin" entry name
  prepare_case bad
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  write_usage 900000

  printf '%s' '{' | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "bad json must exit 0, got $rc"
  assert_silent "bad json"

  rc=0
  printf '%s' '' | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "empty payload must exit 0, got $rc"
  assert_silent "empty payload"

  rc=0
  printf '%s\n' '{"cursor_version":"1.0.0","session_id":"s1","transcript_path":"'"$CASE_TRANSCRIPT"'"}' \
    | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "cursor payload must exit 0, got $rc"
  assert_silent "cursor payload"

  rc=0
  payload | env -u GROK_HOOK_EVENT GROK_AGENT=1 \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "grok environment must exit 0, got $rc"
  assert_silent "grok environment"
  [ ! -e "$CASE_STATE/.stow-guard.json" ] || fail "a refused payload wrote trigger state"

  mkdir -p "$fakebin"
  for entry in /bin/* /usr/bin/*; do
    [ -x "$entry" ] || continue
    name=${entry##*/}
    [ "$name" = jq ] && continue
    ln -s "$entry" "$fakebin/$name" 2>/dev/null || true
  done
  rm -f "$fakebin/jq"
  PATH="$fakebin" command -v dirname >/dev/null 2>&1 || fail "fixture PATH lost dirname"
  PATH="$fakebin" command -v jq >/dev/null 2>&1 && fail "fixture PATH still finds jq"
  rc=0
  payload | env -u GROK_AGENT -u GROK_HOOK_EVENT PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "missing jq"
  [ ! -e "$CASE_STATE/.stow-guard.json" ] || fail "missing jq wrote trigger state"
  pass "bad json, an empty payload, a cursor payload, grok, and a missing jq all stay silent"
}

test_overlong_token_line_keeps_the_default() {
  local rc=0
  prepare_case overlong
  printf 'tokens=999999999999\n' > "$CASE_CONFIG/stow-guard"
  write_usage 300000
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "over-long token line must exit 0, got $rc: $(cat "$ERR")"
  assert_block "over-long token line" "context is 300000 tokens"
  pass "a token line past integer range keeps the 300000 default and still asks"
}

test_tracked_stop_hook_is_synchronous_and_grok_inert() {
  local matches
  matches=$(jq -e '
    [.hooks.Stop[0].hooks[]
      | select(.command | contains("/bin/fm-stow-guard.sh"))
      | select(.timeout == 10)
      | select(.asyncRewake | not)
      | select(.command | contains("${GROK_AGENT:-}${GROK_HOOK_EVENT:-}"))]
    | length' "$ROOT/.claude/settings.json") \
    || fail "tracked Stop hooks could not be read"
  [ "$matches" -eq 1 ] || fail "expected one synchronous grok-inert Stop hook for fm-stow-guard.sh, saw $matches"
  matches=$(jq -e '
    [.hooks.UserPromptSubmit[].hooks[]
      | select(.command | contains("/bin/fm-stow-guard.sh prompt"))
      | select(.timeout == 10)
      | select(.asyncRewake | not)
      | select(.command | contains("${GROK_AGENT:-}${GROK_HOOK_EVENT:-}"))]
    | length' "$ROOT/.claude/settings.json") \
    || fail "tracked UserPromptSubmit hooks could not be read"
  [ "$matches" -eq 1 ] || fail "expected one synchronous grok-inert UserPromptSubmit hook for fm-stow-guard.sh prompt, saw $matches"
  pass "tracked Claude settings run fm-stow-guard.sh once at Stop and once as prompt, synchronously, and inert under grok"
}

fm_test_run \
  test_absent_config_is_silent \
  test_context_crossing_blocks_once_until_rearm \
  test_guard_ask_never_offers_a_restart \
  test_typed_stow_records_the_offer \
  test_typed_stow_quick_records_no_offer \
  test_fleet_sent_stow_records_no_offer \
  test_typed_stow_outside_the_primary_session_records_no_offer \
  test_continuation_stop_blocks_once_per_crossing \
  test_age_interval_blocks_once_per_hour \
  test_recorded_stow_sets_the_age_clock \
  test_each_ask_names_its_pass \
  test_quick_save_does_not_move_the_full_pass_clock \
  test_both_asks_due_asks_quick_then_full_below_the_line \
  test_crew_worktree_is_silent \
  test_secondmate_home_is_silent \
  test_missing_python_skips_the_age_ask \
  test_bad_payloads_and_missing_jq_are_silent \
  test_overlong_token_line_keeps_the_default \
  test_tracked_stop_hook_is_synchronous_and_grok_inert

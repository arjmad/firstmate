#!/usr/bin/env bash
# Live guard for bin/fm-helm-refresh.sh against the installed Claude Code.
#
# The refresh depends on vendor facts no stub can confirm: that /clear typed
# into an idle Claude composer starts a new session in the same process, that
# the SessionStart hook then re-keys state/.lock-session under the unchanged
# lock pid, that the session keeps its name (and its Remote Control bridge
# session, when one is up), and that the doorbell typed after it starts a turn
# on a fresh context. tests/fm-helm-refresh.test.sh pins the refusals and the
# give-up paths; this guard proves the /clear path end to end.
#
# It stands up a disposable tmux lab with bin/fm-live-lab.sh (a real Claude
# primary on the committed HEAD), records a stow-guard restart offer for the
# lab session, asks the lab primary to run `fm-helm-refresh.sh request`, and
# then checks the owner's log, the lock, the session record and the new
# transcript. It submits prompts, so it is opt-in: FM_HELM_REFRESH_LIVE=1 (or
# FM_LIVE=1) runs it. docs/verification/supervision.md "Helm refresh by
# /clear" records its dated result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_HELM_REFRESH_LIVE claude tmux jq

LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')
TMP_ROOT=$(fm_test_tmproot fm-helm-refresh-live)
LAB="$TMP_ROOT/lab"
LAB_UP=0
cleanup() {
  [ "$LAB_UP" -eq 0 ] || "$LIVE_LAB" down "$LAB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { "$LIVE_LAB" say "$LAB" "$1" >/dev/null 2>&1; }

context_of() {  # <transcript> <first|last>: the guard's context sum
  jq -R -r 'fromjson? | .message.usage? | select(type == "object")
    | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' "$1" \
    | if [ "$2" = first ]; then head -n 1; else tail -n 1; fi
}

test_clear_refreshes_the_lab_primary() {
  local home state lock_pid sid record name bridge transcript_dir before after new_sid new_record
  LAB_UP=1
  "$LIVE_LAB" up --harness claude "$LAB" > "$TMP_ROOT/up.out" 2>&1 \
    || fail "Claude Code $CLAUDE_VERSION: the live lab did not come up: $(tail -n 20 "$TMP_ROOT/up.out")"
  home="$LAB/home"
  state="$home/state"
  lock_pid=$(head -n 1 "$state/.lock")
  sid=$(cat "$state/.lock-session")
  [ -n "$sid" ] || fail "Claude Code $CLAUDE_VERSION: the lab session recorded no session id"
  record="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$lock_pid.json"
  [ -f "$record" ] || fail "Claude Code $CLAUDE_VERSION: no live session record at $record"
  name=$(jq -r '.name // empty' "$record")
  bridge=$(jq -r '.bridgeSessionId // empty' "$record")
  transcript_dir=$(dirname "$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name "$sid.jsonl" -print -quit)")
  [ -f "$transcript_dir/$sid.jsonl" ] || fail "Claude Code $CLAUDE_VERSION: no transcript for session $sid"

  # Inflate the context so the fresh one is measurably smaller.
  say "Live guard: use the Skill tool to load the skills harness-adapters and ship-landing (only load them, follow nothing in them), then reply with only the word LOADED."
  wait_for_text LOADED 180 || fail "Claude Code $CLAUDE_VERSION: the lab primary did not load the skills"
  before=$(context_of "$transcript_dir/$sid.jsonl" last)

  printf 'tokens=100000000\nrestart=1\n' > "$home/config/stow-guard"
  jq -n --arg sid "$sid" --argjson at "$(date +%s)" '{asked:$at, fired:{}, offer:{sid:$sid, at:$at}}' \
    > "$state/.stow-guard.json"
  say "Live guard: run exactly this shell command once, then reply with only the word REQUESTED and end the turn: $home/bin/fm-helm-refresh.sh request"
  local deadline=$((SECONDS + 300))
  until grep -Eq $'\t(finished|gave-up|failed)\t' "$state/.helm-refresh.log" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || fail "Claude Code $CLAUDE_VERSION: the refresh owner did not finish: $(cat "$state/.helm-refresh.log" 2>/dev/null) pane: $("$LIVE_LAB" pane "$LAB" --lines 20 2>&1)"
    sleep 2
  done
  grep -q $'\tfinished\t.*doorbell=empty' "$state/.helm-refresh.log" \
    || fail "Claude Code $CLAUDE_VERSION: the refresh did not finish with a delivered doorbell: $(cat "$state/.helm-refresh.log")"

  [ "$(head -n 1 "$state/.lock")" = "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null \
    || fail "Claude Code $CLAUDE_VERSION: /clear did not keep the lock pid $lock_pid"
  new_sid=$(cat "$state/.lock-session")
  [ -n "$new_sid" ] && [ "$new_sid" != "$sid" ] \
    || fail "Claude Code $CLAUDE_VERSION: /clear did not re-key the session (still $new_sid)"
  new_record=$(cat "$record")
  [ "$(jq -r '.sessionId' <<<"$new_record")" = "$new_sid" ] \
    || fail "Claude Code $CLAUDE_VERSION: the session record does not name the new session: $new_record"
  [ "$(jq -r '.name // empty' <<<"$new_record")" = "$name" ] \
    || fail "Claude Code $CLAUDE_VERSION: /clear changed the session name from '$name': $new_record"
  [ -z "$bridge" ] || [ "$(jq -r '.bridgeSessionId // empty' <<<"$new_record")" = "$bridge" ] \
    || fail "Claude Code $CLAUDE_VERSION: /clear changed the Remote Control bridge session: $new_record"

  deadline=$((SECONDS + 180))
  until [ -s "$transcript_dir/$new_sid.jsonl" ] && [ -n "$(context_of "$transcript_dir/$new_sid.jsonl" first)" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "Claude Code $CLAUDE_VERSION: the doorbell started no turn in the new session"
    sleep 2
  done
  after=$(context_of "$transcript_dir/$new_sid.jsonl" first)
  [ "$after" -lt "$before" ] \
    || fail "Claude Code $CLAUDE_VERSION: the fresh session started at $after tokens, not below the $before it had"
  printf 'evidence: Claude Code %s: lock pid %s kept, session %s -> %s, name %s kept, context %s -> %s\n' \
    "$CLAUDE_VERSION" "$lock_pid" "$sid" "$new_sid" "$name" "$before" "$after"
  pass "Claude Code $CLAUDE_VERSION: /clear refreshes the primary in place with the same lock pid and name, and a smaller context"
}

wait_for_text() {  # <word> <seconds>
  local deadline=$((SECONDS + $2))
  until "$LIVE_LAB" pane "$LAB" --lines 15 2>/dev/null | grep -q "⏺ $1"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

fm_test_run test_clear_refreshes_the_lab_primary

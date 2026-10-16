#!/usr/bin/env bash
# Opt-in credentialed live guard for a captain question that holds a Claude
# primary's turn open (bin/fm-question-pretool-check.sh,
# bin/fm-question-keeper.sh, docs/supervision-host.md "While a captain question
# is open").
#
# Proves against the real installed Claude Code, in an isolated lab copy of this
# checkout that runs the supervision host (never a live fleet home), the facts
# the keeper rests on:
#   1. a present captain, with work under way, gets the selector: the tracked
#      guard allows AskUserQuestion and the tracked async keeper records the
#      open question while the selector holds the turn open;
#   2. the Stop hook's park from the previous turn keeps running under the open
#      question and holds the close it would hand to main (the decision
#      itself, or the captain outcome its engine turn recorded) instead of
#      rewaking main;
#   3. answering writes the question's tool result to the transcript, the
#      keeper ends, and its held rewake is delivered into the same turn, which
#      drains and acknowledges the close;
#   4. cancelling a second question with Escape also writes its tool result,
#      so the keeper ends there too, silently, with nothing held.
# The one event is a decision; the host may route it to an engine turn before
# holding its outcome, which spends that turn's tokens. Evidence lines start
# with "# ".
#
#   FM_QUESTION_KEEPER_LIVE_E2E=1 tests/fm-question-keeper-live-e2e.test.sh
#
# FM_QUESTION_KEEPER_LIVE_MODEL (default haiku) picks the primary's model.
# Claude keeps its existing managed authentication; the lab path gets a
# workspace-trust entry and a project transcript directory in Claude's own store.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

fm_live_gate opt-in FM_QUESTION_KEEPER_LIVE_E2E claude tmux jq node perl git

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
MODEL=${FM_QUESTION_KEEPER_LIVE_MODEL:-haiku}
LAB=$(fm_test_tmproot fm-question-keeper-live)
LAB=$(cd -P "$LAB" && pwd -P)
FM="$LAB/fm"
SOCK="fmqkl-$$"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
POLLS=${FM_QUESTION_KEEPER_LIVE_POLLS:-1800}
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_ALLOW_QUESTION_TOOL \
  TMUX TMUX_PANE PI_CODING_AGENT NO_MISTAKES_GATE
# Claude Code keeps no transcript for a session that inherits another session's
# markers, so the lab primary starts without the invoking session's.
while IFS= read -r name; do
  unset "$name"
done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | cut -d= -f1 | sort -u)

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }

cleanup() {
  local pid
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  sleep 1
  if [ -f "$FM/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  fi
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  rm -rf "${PROJECTS:?}/$(printf '%s' "$FM" | sed 's/[^A-Za-z0-9]/-/g')"
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

transcript() {
  find "$PROJECTS/$(printf '%s' "$FM" | sed 's/[^A-Za-z0-9]/-/g')" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | head -n 1
}
# Rewakes Claude queued for delivery at or after <epoch>, whose text contains <text>.
rewoke_since() {  # <epoch> <text>
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -e --argjson since "$1" --arg text "$2" '
    select(.type == "queue-operation" and .operation == "enqueue")
    | select((.content // "" | tostring) | contains($text))
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)' "$t" >/dev/null 2>&1
}
acked_since() {  # <epoch>
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -r --argjson since "$1" '
    select(.type == "assistant")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)
    | .message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command' "$t" 2>/dev/null \
    | grep -q 'fm-wake-drain.sh --ack-through [0-9]* --recovery-generation'
}
turn_ended_since() {  # <epoch>
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -e --argjson since "$1" '
    select(.type == "system" and .subtype == "turn_duration")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)' "$t" >/dev/null 2>&1
}
asked_since() {  # <epoch>: the primary called AskUserQuestion
  local t
  t=$(transcript)
  [ -n "$t" ] || return 1
  jq -e --argjson since "$1" '
    select(.type == "assistant")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)
    | .message.content[]? | select(.type == "tool_use" and .name == "AskUserQuestion")' "$t" >/dev/null 2>&1
}
host_pid() { awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host" 2>/dev/null; }
host_live() { local pid; pid=$(host_pid) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
watcher_live() { local pid; pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
question_open() { [ -s "$FM/state/.question-open" ]; }
question_closed() { [ ! -e "$FM/state/.question-open" ]; }
held() { [ -s "$FM/state/.question-held" ]; }
screen() { tmux -L "$SOCK" capture-pane -p -t primary 2>/dev/null; }
selector_open() { screen | grep -q 'Esc to cancel'; }
diagnose() {
  printf -- '--- host log\n%s\n--- queue\n%s\n--- open: %s\n--- held: %s\n--- screen\n%s\n' \
    "$(tail -n 8 "$FM/state/.supervision-host.log" 2>/dev/null)" "$(cat "$FM/state/.wake-queue" 2>/dev/null)" \
    "$(cat "$FM/state/.question-open" 2>/dev/null)" "$(cat "$FM/state/.question-held" 2>/dev/null)" \
    "$(screen | tail -n 25)"
}

choose() {  # <screen> <option>
  local cursor target moves key
  cursor=$(printf '%s\n' "$1" | grep -n '❯' | head -n 1 | cut -d: -f1)
  target=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -n 1 | cut -d: -f1)
  [ -n "$cursor" ] && [ -n "$target" ] || return 0
  moves=$((target - cursor))
  key=Down
  [ "$moves" -ge 0 ] || { key=Up; moves=$((0 - moves)); }
  while [ "$moves" -gt 0 ]; do
    tmux -L "$SOCK" send-keys -t primary "$key"
    sleep 0.3
    moves=$((moves - 1))
  done
  tmux -L "$SOCK" send-keys -t primary Enter
  sleep 3
}
claude_ready() {
  local busy composer
  tmux() { command tmux -L "$SOCK" "$@"; }
  busy=$(fm_pane_busy_state primary claude)
  composer=$(fm_tmux_composer_state primary)
  unset -f tmux
  [ "$busy" = idle ] && [ "$composer" = empty ]
}
submit() {  # <prompt>
  tmux -L "$SOCK" send-keys -t primary -l "$1"
  sleep 1
  tmux -L "$SOCK" send-keys -t primary Enter
}

# --- the lab ------------------------------------------------------------------

mkdir -p "$FM" "$LAB/bin"
git -C "$ROOT" ls-files -z -co --exclude-standard \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
git -C "$FM" init -q -b main
git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config" "$FM/data"
: > "$FM/config/supervision-host"
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$FM/state/demo.meta"
: > "$FM/state/demo.status"
# An unreachable tmux: the watcher reads no endpoint, so the only wakes are the
# events this guard appends.
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
cat > "$LAB/env" <<ENV
export FM_HOME='$FM'
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0
export PATH='$LAB/bin':"\$PATH"
ENV
jq -e '[.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[]
    | select(.command | contains("fm-question-keeper.sh")) | select(.asyncRewake == true)] | length == 1' \
  "$FM/.claude/settings.json" >/dev/null || fail "the lab lacks the tracked async keeper registration"

SETUP='This is an isolated Firstmate test lab, not a real fleet. Reply with exactly READY now and use no tools. Later, whenever a "Stop hook feedback" message wakes you, do exactly this and nothing else: run `bin/fm-wake-drain.sh` once with the Bash tool, then run the exact `bin/fm-wake-drain.sh --ack-through ...` command that its WAKE_ACK_REQUIRED line prints, then reply with exactly ACKED. Never run bin/fm-watch-arm.sh.'
ASK='Call the AskUserQuestion tool now with exactly one question, "Pick a color", with the options Red and Blue. After the answer, reply with the chosen color in one word, unless a "Stop hook feedback" message arrives, which you handle as instructed earlier first.'

started=$(date +%s)
tmux -L "$SOCK" new-session -d -s primary -x 220 -y 50 -c "$FM" \
  "sh -c '. \"$LAB/env\"; printf \"%s\\n\" \"\$\$\" > state/.lock; exec claude --model $MODEL --effort low --dangerously-skip-permissions'" \
  || fail "the tmux session did not start"
i=0
while [ "$i" -lt 90 ]; do
  s=$(screen)
  case "$s" in
    *'Yes, I trust this folder'*) choose "$s" 'Yes, I trust this folder' ;;
    *'Yes, I accept'*) choose "$s" 'Yes, I accept' ;;
    *'external CLAUDE.md'*|*'external imports'*) choose "$s" 'Yes, allow external imports' ;;
    *) claude_ready && break ;;
  esac
  sleep 1
  i=$((i + 1))
done
[ "$i" -lt 90 ] || fail "Claude $CLAUDE_VERSION never reached an idle empty composer"$'\n'"$(diagnose)"
sleep 2
submit "$SETUP"
wait_until "$POLLS" host_live || fail "the setup turn's Stop hook never started the supervision host"$'\n'"$(diagnose)"
wait_until 300 watcher_live || fail "the host never started a watcher"$'\n'"$(diagnose)"
wait_until "$POLLS" turn_ended_since "$started" || fail "the setup turn never ended"$'\n'"$(diagnose)"
PARKED=$(host_pid)
evidence "setup: primary idle (claude pid $(cat "$FM/state/.lock"), $CLAUDE_VERSION, model $MODEL); Stop hook host $PARKED parked; transcript $(transcript)"

# 1. A present captain asks for the selector with work under way.
asked=$(date +%s)
wait_until 300 claude_ready || fail "the primary is not idle before the question"$'\n'"$(diagnose)"
submit "$ASK"
wait_until "$POLLS" asked_since "$asked" || fail "the primary never called AskUserQuestion"$'\n'"$(diagnose)"
wait_until 300 question_open || fail "step 1: the keeper never recorded the open question, so the guard denied it or the keeper did not run"$'\n'"$(diagnose)"
wait_until 300 selector_open || fail "step 1: the selector never opened"$'\n'"$(diagnose)"
evidence "step 1: guard allowed AskUserQuestion; keeper recorded $(cut -f1,3 "$FM/state/.question-open" | tr '\t' ' '); selector open"

# 2. A decision while the question is open is held by the running park.
fired=$(date +%s)
printf 'needs-decision [at=%s] [key=fmt]: which export format?\n' "$fired" >> "$FM/state/demo.status"
wait_until 1200 held || fail "step 2: the close for main was not held"$'\n'"$(diagnose)"
sleep 3
rewoke_since "$fired" 'firstmate watcher wake' && fail "step 2: main was rewoken while its question was open"$'\n'"$(diagnose)"
[ "$(host_pid)" = "$PARKED" ] || fail "step 2: the parked host $PARKED was replaced by $(host_pid)"
selector_open || fail "step 2: the selector closed before the answer"$'\n'"$(diagnose)"
evidence "step 2: held $(head -n 1 "$FM/state/.question-held" | cut -c1-100)...; host $PARKED still parked"
evidence "step 2: host log since the event: $(awk -F '\t' -v t="$fired" '$1 >= t { print $2 "/" $3 }' "$FM/state/.supervision-host.log" | cut -c1-60 | tr '\n' ';')"

# 3. The answer ends the keeper, whose rewake reaches the same turn.
answered=$(date +%s)
tmux -L "$SOCK" send-keys -t primary Enter
wait_until 300 question_closed || fail "step 3: the answer did not end the keeper"$'\n'"$(diagnose)"
wait_until "$POLLS" rewoke_since "$answered" 'not a block on your question' \
  || fail "step 3: the keeper's held rewake was not delivered"$'\n'"$(diagnose)"
wait_until "$POLLS" acked_since "$answered" || fail "step 3: the primary never drained and acknowledged the held close"$'\n'"$(diagnose)"
[ -s "$FM/state/.question-answered" ] || fail "step 3: the answer was not stamped as presence"
evidence "step 3: keeper ended on the transcript tool result; rewake delivered and acknowledged; presence stamp $(cut -f1 "$FM/state/.question-answered")"
wait_until "$POLLS" turn_ended_since "$answered" || fail "step 3: the answering turn never ended"$'\n'"$(diagnose)"

# 4. Escape on a second question closes it the same way.
asked=$(date +%s)
wait_until 300 claude_ready || fail "the primary is not idle before the second question"$'\n'"$(diagnose)"
submit "$ASK"
wait_until "$POLLS" asked_since "$asked" || fail "step 4: the primary never called AskUserQuestion again"$'\n'"$(diagnose)"
wait_until 300 question_open || fail "step 4: the keeper never recorded the second question"$'\n'"$(diagnose)"
wait_until 300 selector_open || fail "step 4: the second selector never opened"$'\n'"$(diagnose)"
cancelled=$(date +%s)
tmux -L "$SOCK" send-keys -t primary Escape
wait_until 300 question_closed || fail "step 4: Escape did not end the keeper"$'\n'"$(diagnose)"
sleep 3
rewoke_since "$cancelled" 'not a block on your question' && fail "step 4: a keeper with nothing held rewoke main"
evidence "step 4: Escape wrote the tool result and the keeper ended silently"

pass "question keeper live ($CLAUDE_VERSION): a present captain keeps the selector, the running park holds main's close while it is open, and the answer delivers it into the same turn"

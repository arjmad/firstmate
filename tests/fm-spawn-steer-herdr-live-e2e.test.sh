#!/usr/bin/env bash
# tests/fm-spawn-steer-herdr-live-e2e.test.sh - the live spawn-and-steer smoke
# guard (live-harness-optin family).
#
# A Firstmate worker is only useful if firstmate can reach it after it goes
# idle. That path crosses three owners: bin/fm-spawn.sh builds the launch
# command (including the Claude session name), the harness draws its composer,
# and bin/fm-composer-lib.sh plus the backend adapter prove a doorbell landed in
# that composer. Each owner has portable tests, but only a real launch shows how
# a change in one reads through the others: firstmate PR 87 added the Claude
# --name flag, the name drew a titled composer rule that the composer proof did
# not accept once the doorbell wrapped, and every Herdr steer to a worker
# spawned after it failed until PR 88. The other live doorbell guard launches
# each harness by hand on tmux, so it could not see either change.
#
# This guard therefore drives the real entrypoints end to end: bin/fm-spawn.sh
# launches a real Claude ship worker from a scaffolded brief on the Herdr
# backend, the test waits until that worker has finished its first turn and is
# idle, checks that its composer carries the session name, and steers it with
# the real bin/fm-send.sh. The worker must act on the steer (create a named
# file) and acknowledge it (mv the record into handled/), and fm-send must not
# report that its doorbell missed. It fails naming the Claude and Herdr
# versions.
#
# Isolation: every Herdr call, including those fm-spawn and fm-send make
# through bin/backends/herdr.sh, reaches the named lab session through
# bin/fm-herdr-lab.sh by a PATH wrapper that refuses any other session; the
# lab helper verifies the default fleet session is unchanged at teardown. The
# lab home, the scratch project and its origin, and the Treehouse pool
# (TREEHOUSE_ROOT) all live under one temporary root. The spawn registers
# Claude workspace trust for the worker's worktree; cleanup removes every
# Claude project entry under that root with bin/fm-live-lab.sh forget-claude.
#
# Run it with FM_SPAWN_STEER_LIVE=1 (or FM_LIVE=1) before merging a change to
# launch, session naming, or composer code; bin/fm-test-run.sh --changed
# selects it for those files. It spends one short Claude worker turn plus one
# steered turn. FM_SPAWN_STEER_LIVE_MODEL (default sonnet) and
# FM_SPAWN_STEER_LIVE_TIMEOUT (seconds per wait, default 300) tune it. Record
# the dated result in docs/verification/runtime-backends.md ("Spawn-and-steer
# smoke").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate opt-in FM_SPAWN_STEER_LIVE herdr jq claude treehouse node git python3

[ -x "$LAB_HELPER" ] || fail "the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

unset NO_MISTAKES_GATE
ORIGINAL_PATH=$PATH
TIMEOUT=${FM_SPAWN_STEER_LIVE_TIMEOUT:-300}
MODEL=${FM_SPAWN_STEER_LIVE_MODEL:-sonnet}
case "$TIMEOUT" in ''|*[!0-9]*) fail "FM_SPAWN_STEER_LIVE_TIMEOUT takes seconds" ;; esac
SESSION=$("$LAB_HELPER" name spawn-steer-live) || fail "could not name an isolated Herdr lab session"
TMP_ROOT=
LAB_HOME=
ID="steer$$x$RANDOM"
PROVISIONED=0

# The pool lives under TMP_ROOT, so the operator's ~/.treehouse must not gain an
# entry; bin/fm-live-lab.sh down holds labs to the same check.
TREEHOUSE_DIR="$HOME/.treehouse"
treehouse_listing() { find "$TREEHOUSE_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | sort; }
TREEHOUSE_BEFORE=$(treehouse_listing)

cleanup() {
  local rc=$? home_hash dir added
  trap - EXIT
  if [ "$PROVISIONED" = 1 ] && ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  # A spawn keeps /tmp/fm-<id> and /tmp/fm-<id>+<sha256 of the spawning home>;
  # the id is unique to this run. Claude may have recorded a project entry for
  # either, so each is forgotten before it is removed.
  home_hash=$(printf '%s' "$LAB_HOME" | shasum -a 256 | awk '{print $1}')
  for dir in "$TMP_ROOT" "/tmp/fm-$ID" "/tmp/fm-$ID+$home_hash"; do
    [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || continue
    if ! "$ROOT/bin/fm-live-lab.sh" forget-claude "$dir" >/dev/null; then
      printf 'not ok - could not remove the Claude project entries under %s\n' "$dir" >&2
      rc=1
    fi
    [ "$dir" = "$TMP_ROOT" ] || rm -rf "$dir"
  done
  added=$(comm -13 <(printf '%s\n' "$TREEHOUSE_BEFORE") <(treehouse_listing))
  if [ -n "$added" ]; then
    printf 'not ok - ~/.treehouse gained entries during the run; left as is: %s\n' "$(printf '%s' "$added" | tr '\n' ' ')" >&2
    rc=1
  fi
  if [ -n "$TMP_ROOT" ]; then
    chmod -R u+w "$TMP_ROOT" 2>/dev/null
    rm -rf "$TMP_ROOT"
  fi
  exit "$rc"
}
trap cleanup EXIT

# Under /tmp, the temporary root bin/fm-live-lab.sh forget-claude accepts. The
# trap is already set, so a failure from here on still removes it.
TMP_ROOT=$(mktemp -d /tmp/fm-spawn-steer-live.XXXXXX) || fail "could not create the temporary lab root under /tmp"
TMP_ROOT=$(cd -P "$TMP_ROOT" && pwd -P) || fail "could not resolve the temporary lab root"
LAB_HOME="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"

# fm-spawn and fm-send reach Herdr through bare `herdr` calls that end in
# --session <name>; only this lab's session passes, through the lab helper. The
# adapter's client version check (`herdr status --json`) and `--version` carry
# no session; the first is answered by the lab session and the second by the
# client alone.
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$*" = --version ]; then
  exec env PATH="$ORIGINAL_PATH" herdr --version
elif [ "\$*" = 'status --json' ]; then
  :
elif [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# The spawn types `treehouse get` into the worker's pane, whose shell inherits
# the lab server's environment rather than the spawn's, so the lab pool root is
# exported before the server starts and proved from a lab pane before any spawn.
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse" DISABLE_AUTOUPDATER=1
mkdir -p "$TREEHOUSE_ROOT"
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
PROVISIONED=1
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
PROBE_PANE=$(lab workspace create --cwd "$TMP_ROOT" --label fm-steer-probe --no-focus 2>/dev/null \
  | jq -er '.result.root_pane.pane_id') || fail "could not create the lab pool-root probe pane"
lab pane run "$PROBE_PANE" "printf '%s' \"\$TREEHOUSE_ROOT\" > '$TMP_ROOT/root-probe'" >/dev/null \
  || fail "could not run the lab pool-root probe"
i=0
while [ "$i" -lt 30 ] && [ ! -s "$TMP_ROOT/root-probe" ]; do
  i=$((i + 1))
  sleep 1
done
[ "$(cat "$TMP_ROOT/root-probe" 2>/dev/null)" = "$TREEHOUSE_ROOT" ] \
  || fail "a lab pane does not see the lab Treehouse root (saw '$(cat "$TMP_ROOT/root-probe" 2>/dev/null)'); refusing to spawn into the fleet's pool"

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
WHO="Claude Code (${CLAUDE_VERSION:-version-unknown}) on ${HERDR_VERSION:-herdr-unknown}"

# --- the lab home and its one project ------------------------------------------

"$ROOT/bin/fm-lab-home.sh" create "$LAB_HOME" >/dev/null || fail "could not create the lab home"
mkdir -p "$LAB_HOME/config" "$LAB_HOME/data" "$LAB_HOME/projects" "$TMP_ROOT/origins"
printf 'herdr\n' > "$LAB_HOME/config/backend"
printf 'off\n' > "$LAB_HOME/config/herdr-presentation-spaces"
SEED="$TMP_ROOT/origins/smoke-seed"
git init -q -b main "$SEED"
printf '# smoke\n\nA scratch project for the spawn-and-steer smoke guard.\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "seed smoke"
git clone -q --bare "$SEED" "$TMP_ROOT/origins/smoke.git"
git clone -q "$TMP_ROOT/origins/smoke.git" "$LAB_HOME/projects/smoke"
printf '# Projects\n\n- smoke [local-only] - scratch project for the spawn-and-steer smoke guard\n' > "$LAB_HOME/data/projects.md"

# The paused verb is pinned to its default so the brief and the wait below agree.
in_lab() {  # <command...>: run with the lab home, the lab pool, and the Herdr wrapper
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u FM_CLASSIFY_PAUSED_VERB \
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
    FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 "$@"
}

(cd "$LAB_HOME" && in_lab "$ROOT/bin/fm-brief.sh" "$ID" smoke --mode local-only) >/dev/null \
  || fail "could not scaffold the smoke worker's brief"
TASK_TEXT="Smoke worker for a live spawn-and-steer check. Right after setup, append one paused status line saying you are waiting for a firstmate message, then end your turn. When a firstmate message arrives in your steering inbox, do exactly what it says, acknowledge it as this brief describes, and end your turn." \
SPEC_TEXT="Nothing else is in scope: do not edit the project, commit, push, open a pull request, or poll or sleep in a foreground command." \
  python3 - "$LAB_HOME/data/$ID/brief.md" <<'PY' || fail "could not fill the smoke worker's brief"
import os, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"], 1)
open(path, "w", encoding="utf-8").write(text)
PY

# --- spawn through the real launch path ----------------------------------------

(cd "$LAB_HOME" && in_lab "$ROOT/bin/fm-spawn.sh" "$ID" "$LAB_HOME/projects/smoke" \
  --mode local-only --yolo off --harness claude --model "$MODEL" --effort low --backend herdr) \
  > "$TMP_ROOT/spawn.out" 2>&1 \
  || fail "fm-spawn could not launch a Claude worker for $WHO: $(tail -5 "$TMP_ROOT/spawn.out")"
TARGET=$(sed -n 's/^window=//p' "$LAB_HOME/state/$ID.meta" | head -n 1)
PANE=${TARGET#*:}
[ "${TARGET%%:*}" = "$SESSION" ] && [ -n "$PANE" ] && [ "$PANE" != "$TARGET" ] \
  || fail "the spawn recorded no pane in the lab session (window=$TARGET)"
WORKTREE=$(sed -n 's/^worktree=//p' "$LAB_HOME/state/$ID.meta" | head -n 1)
case "$WORKTREE" in
  "$TREEHOUSE_ROOT"/*) ;;
  *) fail "the worker's worktree '$WORKTREE' is outside the lab Treehouse root $TREEHOUSE_ROOT" ;;
esac

# The worker reads its brief, records that it waits, and ends its first turn.
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  grep -q '^paused' "$LAB_HOME/state/$ID.status" 2>/dev/null && break
  i=$((i + 1))
  sleep 1
done
grep -q '^paused' "$LAB_HOME/state/$ID.status" 2>/dev/null \
  || fail "$WHO: the spawned worker never reported its wait within ${TIMEOUT}s: $(lab pane read "$PANE" --source visible 2>/dev/null | grep '[^[:space:]]' | tail -8)"
idle=0
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  case "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" in
    idle|done) idle=1; break ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "$WHO: the spawned worker never went idle after its first turn"

# The steer must cross the composer the launch actually drew, so the case is
# vacuous unless that composer carries the session name the spawn gave it.
lab pane read "$PANE" --source visible 2>/dev/null | grep -F "ship: $ID" >/dev/null \
  || fail "$WHO: the idle worker's screen does not show its session name 'ship: $ID'; the launch path this guard exists for was not exercised"
pass "$WHO: fm-spawn launched a named Claude worker in isolated session $SESSION and it went idle"

# --- steer the idle worker through the real send path ---------------------------

ACTED="$TMP_ROOT/acted"
in_lab "$ROOT/bin/fm-send.sh" "$ID" \
  "Firstmate smoke steer: run exactly this shell command now: touch $ACTED - then acknowledge this message as your brief describes and end your turn." \
  > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err" \
  || fail "$WHO: fm-send refused the steer: $(cat "$TMP_ROOT/send.err")"
! grep -F 'doorbell did not reach' "$TMP_ROOT/send.err" >/dev/null \
  || fail "$WHO: fm-send's doorbell did not reach the idle named worker: $(cat "$TMP_ROOT/send.err")"
RECORD="$LAB_HOME/state/$ID.inbox/001.msg"
HANDLED="$LAB_HOME/state/$ID.inbox/handled/001.msg"
[ -f "$RECORD" ] || [ -f "$HANDLED" ] || fail "fm-send left no durable inbox record"
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  [ -f "$HANDLED" ] && [ -e "$ACTED" ] && break
  i=$((i + 1))
  sleep 1
done
if [ ! -f "$HANDLED" ] || [ ! -e "$ACTED" ]; then
  note "pane tail:"
  lab pane read "$PANE" --source recent --lines 40 2>/dev/null | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  fail "$WHO: the idle worker did not honor the steer within ${TIMEOUT}s (acted=$([ -e "$ACTED" ] && echo yes || echo no) acked=$([ -f "$HANDLED" ] && echo yes || echo no))"
fi
pass "$WHO: fm-send's doorbell reached the idle named worker, which acted and acknowledged"

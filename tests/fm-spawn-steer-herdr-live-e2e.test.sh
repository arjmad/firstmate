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
# report that its doorbell missed. It then stops and restarts the lab session's
# Herdr server, attaches a viewer so Herdr's native agent resume runs, and
# checks that the restored pane resumed the same Claude session through the
# resume command the launch reported (bin/fm-herdr-claude-resume.sh): with its
# --settings, permission mode, model, effort, --add-dir grant and name, and,
# when FM_SPAWN_STEER_LIVE_ACCOUNT names a signed-in Claude config directory to
# pin the worker to, on that CLAUDE_CONFIG_DIR rather than the ambient store.
# It fails naming the Claude and Herdr versions.
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
# steered turn; the resume sends no prompt. FM_SPAWN_STEER_LIVE_MODEL (default
# sonnet), FM_SPAWN_STEER_LIVE_TIMEOUT (seconds per wait, default 300), and
# FM_SPAWN_STEER_LIVE_ACCOUNT (absolute Claude config directory; default none,
# the ordinary store) tune it. Record the dated result in
# docs/verification/runtime-backends.md ("Spawn-and-steer smoke").
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
ACCOUNT=${FM_SPAWN_STEER_LIVE_ACCOUNT:-}
case "$ACCOUNT" in ''|/*) ;; *) fail "FM_SPAWN_STEER_LIVE_ACCOUNT takes an absolute Claude config directory" ;; esac
SESSION=$("$LAB_HELPER" name spawn-steer-live) || fail "could not name an isolated Herdr lab session"
TMP_ROOT=
LAB_HOME=
ID="steer$$x$RANDOM"
PROVISIONED=0
SPAWN_RAN=0

# The pool lives under TMP_ROOT, so the operator's own pool storage must not gain
# an entry; bin/fm-live-lab.sh down holds labs to the same check.
# shellcheck source=tests/treehouse-helpers.sh
. "$ROOT/tests/treehouse-helpers.sh"
TREEHOUSE_DIR=$(fm_treehouse_storage)
treehouse_listing() { find "$TREEHOUSE_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | sort; }
TREEHOUSE_BEFORE=$(treehouse_listing)

# The two temporary directories a spawn of $ID keeps: /tmp/fm-<id> and
# /tmp/fm-<id>+<sha256 of the spawning home>.
# The hash falls back to sha256sum as bin/fm-spawn.sh's does.
task_tmp_dirs() {
  local hash
  [ -n "$LAB_HOME" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$LAB_HOME" | shasum -a 256 | awk '{print $1}')
  else
    hash=$(printf '%s' "$LAB_HOME" | sha256sum | awk '{print $1}')
  fi
  printf '%s\n' "/tmp/fm-$ID" "/tmp/fm-$ID+$hash"
}

# Declare a root this run just created to bin/fm-live-lab.sh forget-claude.
mark_created() {  # <dir>...
  local dir
  for dir in "$@"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || continue
    : > "$dir/.fm-forget-claude" || fail "could not mark $dir for its Claude-entry cleanup"
  done
}

cleanup() {
  local rc=$? dir added keep_root=0 forgotten
  trap - EXIT
  if [ "$PROVISIONED" = 1 ] && ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    # A worker that may still be running could write its Claude entry back, so
    # every root and its entries stay for a later cleanup.
    printf 'not ok - lab teardown failed; kept %s and this run'"'"'s task directories with their Claude entries\n' "${TMP_ROOT:-the temporary root}" >&2
    exit 1
  fi
  # A spawn keeps /tmp/fm-<id> and /tmp/fm-<id>+<sha256 of the spawning home>;
  # the id is unique to this run. Claude may have recorded a project entry for
  # either, so each is forgotten before it is removed, and a root whose forget
  # failed is kept with its marker so a later forget-claude can still clean it.
  # Cleanup never writes the marker: mark_created wrote it as each root was
  # created, so a task directory left unmarked by an interrupted spawn is
  # refused by forget-claude and kept here rather than removed.
  # Task directories are this run's only once its spawn has started.
  for dir in "$TMP_ROOT" $([ "$SPAWN_RAN" = 0 ] || task_tmp_dirs); do
    [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || continue
    forgotten=1
    if ! "$ROOT/bin/fm-live-lab.sh" forget-claude "$dir" >/dev/null; then
      forgotten=0
    fi
    # A pinned spawn registers its trust in the pinned store.
    if [ -n "$ACCOUNT" ] && ! CLAUDE_CONFIG_DIR="$ACCOUNT" "$ROOT/bin/fm-live-lab.sh" forget-claude "$dir" >/dev/null; then
      forgotten=0
    fi
    if [ "$forgotten" = 1 ]; then
      [ "$dir" = "$TMP_ROOT" ] || rm -rf "$dir"
    else
      printf 'not ok - could not remove the Claude project entries under %s; kept it for a later forget-claude\n' "$dir" >&2
      rc=1
      [ "$dir" != "$TMP_ROOT" ] || keep_root=1
    fi
  done
  added=$(comm -13 <(printf '%s\n' "$TREEHOUSE_BEFORE") <(treehouse_listing))
  if [ -n "$added" ]; then
    printf 'not ok - %s gained entries during the run; left as is: %s\n' "$TREEHOUSE_DIR" "$(printf '%s' "$added" | tr '\n' ' ')" >&2
    rc=1
  fi
  if [ -n "$TMP_ROOT" ] && [ "$keep_root" = 0 ]; then
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
mark_created "$TMP_ROOT"
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
[ -z "$ACCOUNT" ] || printf '%s\n' "$ACCOUNT" > "$LAB_HOME/config/claude-account"
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

# fm-spawn can reuse an existing /tmp/fm-<id>, and mark_created below declares
# whatever is there after the spawn, so nothing may be there before it.
# shellcheck disable=SC2046 # Each line is one path without spaces.
for dir in $(task_tmp_dirs); do
  [ ! -e "$dir" ] || fail "$dir already exists before this run's spawn; refusing to declare a directory this run did not create"
done
spawn_rc=0
SPAWN_RAN=1
(cd "$LAB_HOME" && in_lab "$ROOT/bin/fm-spawn.sh" "$ID" "$LAB_HOME/projects/smoke" \
  --mode local-only --yolo off --harness claude --model "$MODEL" --effort low --backend herdr) \
  > "$TMP_ROOT/spawn.out" 2>&1 || spawn_rc=$?
# The spawn just created this run's task directories, whatever its outcome.
# shellcheck disable=SC2046 # Each line is one path without spaces.
mark_created $(task_tmp_dirs)
[ "$spawn_rc" = 0 ] \
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
lab pane read "$PANE" --source visible 2>/dev/null | grep -F "─ $ID ─" >/dev/null \
  || fail "$WHO: the idle worker's composer rule does not show its session name '$ID'; the launch path this guard exists for was not exercised"
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

# --- restore: a Herdr server restart resumes the worker on its launch contract ---

SID=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty')
[ -n "$SID" ] || fail "$WHO: Herdr holds no Claude session for the worker's pane"
RESUME="$LAB_HOME/state/$ID.claude-resume.sh"
[ -f "$RESUME" ] || fail "the spawn left no Herdr resume file at $RESUME"
# The SessionStart hook reports after its last delay (5s); a restart before
# that would test Herdr's bare resume instead.
sleep 8
PATH="$ORIGINAL_PATH" "$LAB_HELPER" stop "$SESSION" >/dev/null || fail "could not stop the lab session"
i=0
while [ "$i" -lt 30 ]; do
  [ "$(lab status --json 2>/dev/null | jq -r '.server.running // empty')" = false ] && break
  i=$((i + 1))
  sleep 1
done
PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$SESSION" >/dev/null || fail "could not restart the lab session"
# Herdr resumes restored agents only once a client attaches.
PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer start "$SESSION" >/dev/null || fail "could not attach a lab viewer"
RESUMED=
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  RESUMED=$(lab pane process-info --pane "$PANE" 2>/dev/null \
    | jq -c '[.result.process_info.foreground_processes[]? | select(.argv | index("--resume"))][0] // empty' 2>/dev/null)
  [ -n "$RESUMED" ] && break
  i=$((i + 1))
  sleep 1
done
[ -n "$RESUMED" ] || fail "$WHO: the restored pane never ran a resumed Claude: $(lab pane read "$PANE" --source visible 2>/dev/null | grep '[^[:space:]]' | tail -8)"
RCWD=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.foreground_cwd // empty')
[ "$RCWD" = "$WORKTREE" ] || fail "$WHO: the resumed Claude runs in '$RCWD', not its worktree $WORKTREE"
ARGV=$(printf '%s' "$RESUMED" | jq -r '.argv[]')
for want in $'--resume\n'"$SID" --dangerously-skip-permissions --settings $'--name\n'"$ID" \
  $'--model\n'"$MODEL" $'--effort\nlow' --add-dir; do
  case $'\n'"$ARGV"$'\n' in
    *$'\n'"$want"$'\n'*) ;;
    *) fail "$WHO: the resumed Claude lost its launch flag '$want'; argv: $(printf '%s' "$ARGV" | tr '\n' ' ')" ;;
  esac
done
RPID=$(printf '%s' "$RESUMED" | jq -r '.pid')
if [ -r "/proc/$RPID/environ" ]; then
  RENV=$(tr '\0' '\n' < "/proc/$RPID/environ")
else
  RENV=$(ps eww -o command= -p "$RPID" 2>/dev/null | tr ' ' '\n')
fi
if [ -n "$ACCOUNT" ]; then
  printf '%s\n' "$RENV" | grep -qxF "CLAUDE_CONFIG_DIR=$ACCOUNT" \
    || fail "$WHO: the resumed Claude does not run on the pinned account $ACCOUNT"
fi
idle=0
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  case "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" in
    idle|done) idle=1; break ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "$WHO: the resumed worker never went idle: $(lab pane read "$PANE" --source visible 2>/dev/null | grep '[^[:space:]]' | tail -8)"
pass "$WHO: a Herdr restore resumed session $SID with its launch flags${ACCOUNT:+ on CLAUDE_CONFIG_DIR=$ACCOUNT}"

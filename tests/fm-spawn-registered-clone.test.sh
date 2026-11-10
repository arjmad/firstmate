#!/usr/bin/env bash
# fm-spawn.sh takes a fresh ship or scout worktree only from a clone directly
# under this home's projects/.
#
# Treehouse keys a pool by the origin URL, so a `treehouse get` run from any
# other checkout of the same repository adds a slot to the shared pool that is
# a worktree of that checkout's .git. A spawn given a live checkout (an absolute
# path, `.` from inside it, a projects/ symlink to it, or a projects/ entry that
# is itself a worktree of it) must refuse before any worktree provider runs.
# A real clone under projects/ must get past the check.
#
# A fake treehouse logs every call; no real pool, window, or worker is created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-registered-clone)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOME_DIR="$TMP_ROOT/home"
LIVE="$TMP_ROOT/live/repo"
FAKEBIN="$TMP_ROOT/fakebin"
TH_LOG="$TMP_ROOT/treehouse.log"
REFUSAL='is not a clone directly under this home'"'"'s projects/'
NOT_OWN='is not its own clone'

commit_repo() {  # <dir>
  git -C "$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
}

setup() {
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN" "$(dirname "$LIVE")"
  touch "$HOME_DIR/state/.last-watcher-beat"
  # Name the crew harness so the spawn never depends on what this host detects.
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  git init -q "$LIVE" || fail "could not create the live checkout fixture"
  commit_repo "$LIVE" || fail "could not commit the live checkout fixture"
  git -C "$LIVE" remote add origin https://example.invalid/acme/repo.git
  git clone -q "$LIVE" "$HOME_DIR/projects/repo" || fail "could not create the registered clone fixture"
  ln -s "$LIVE" "$HOME_DIR/projects/linked"
  git -C "$LIVE" worktree add -q --detach "$HOME_DIR/projects/wt" || fail "could not create the worktree fixture"
  : > "$TH_LOG"
  cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TH_LOG'
exit 1
SH
  chmod +x "$FAKEBIN/treehouse"
}

# run_spawn <cwd> <id> <project> [--scout]: a ship spawn (or a scout) with
# ambient firstmate overrides cleared, so the test owns its environment.
run_spawn() {
  local cwd=$1 id=$2 proj=$3
  shift 3
  [ "$#" -gt 0 ] || set -- --mode direct-PR --yolo off
  (cd "$cwd" && PATH="$FAKEBIN:$PATH" FM_BACKEND=tmux \
    FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE="${PROJECTS_OVERRIDE:-}" FM_CONFIG_OVERRIDE='' \
    FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$proj" "$@" 2>&1)
}

assert_refused() {  # <label> <expected> <cwd> <id> <project> [extra args...]
  local label=$1 expected=$2 out status
  shift 2
  : > "$TH_LOG"
  out=$(run_spawn "$@")
  status=$?
  [ "$status" -ne 0 ] || fail "$label: the spawn succeeded"
  assert_contains "$out" "$expected" "$label: the refusal did not name the projects/ rule"
  [ ! -s "$TH_LOG" ] || fail "$label: treehouse ran before the refusal: $(cat "$TH_LOG")"
  pass "$label"
}

assert_admitted() {  # <label> <cwd> <id> <project>
  local label=$1 out
  shift
  out=$(run_spawn "$@")
  assert_not_contains "$out" "$REFUSAL" "$label: a registered clone was refused"
  assert_not_contains "$out" "$NOT_OWN" "$label: a registered clone was refused as a worktree"
  # These cases carry no brief, so reaching the later brief check proves the
  # spawn went past the projects/ rule rather than failing before it.
  assert_contains "$out" "has no brief" "$label: the spawn stopped before the projects/ rule was passed"
  pass "$label"
}

test_live_checkout_refused() {
  assert_refused "an absolute live-checkout path is refused" "$REFUSAL" "$TMP_ROOT" live-abs "$LIVE"
  assert_refused "a '.' project from inside a live checkout is refused" "$REFUSAL" "$LIVE" live-dot .
  assert_refused "a relative path that leaves projects/ is refused" "$REFUSAL" "$HOME_DIR" live-rel "projects/../../live/repo"
  assert_refused "a projects/ symlink to a live checkout is refused" "$REFUSAL" "$TMP_ROOT" live-link projects/linked
  assert_refused "a projects/ entry that is a worktree of a live checkout is refused" "$NOT_OWN" "$TMP_ROOT" live-wt projects/wt
  assert_refused "a scout from a live checkout is refused" "$REFUSAL" "$TMP_ROOT" live-scout "$LIVE" --scout
  # An inherited GIT_DIR must not make the probe read another repository.
  GIT_DIR="$LIVE/.git" assert_admitted "an inherited GIT_DIR does not refuse a registered clone" "$TMP_ROOT" clone-env projects/repo
  # A projects/ entry that is not its own git clone fails closed.
  mkdir -p "$HOME_DIR/projects/plain"
  assert_refused "a projects/ entry that is not a git clone is refused" "$NOT_OWN" "$TMP_ROOT" plain projects/plain
}

test_registered_clone_admitted() {
  assert_admitted "a projects/<name> clone passes the check" "$TMP_ROOT" clone-rel projects/repo
  assert_admitted "an absolute path to a projects/ clone passes the check" "$TMP_ROOT" clone-abs "$HOME_DIR/projects/repo"
  local alt="$TMP_ROOT/alt-projects"
  mkdir -p "$alt"
  git clone -q "$LIVE" "$alt/repo" || fail "could not create the override clone fixture"
  PROJECTS_OVERRIDE=$alt assert_admitted "a clone under FM_PROJECTS_OVERRIDE passes the check" "$TMP_ROOT" clone-override projects/repo
  PROJECTS_OVERRIDE=$alt assert_refused "the home's projects/ is not trusted under an override" "$REFUSAL" "$TMP_ROOT" clone-home "$HOME_DIR/projects/repo"
}

setup
test_live_checkout_refused
test_registered_clone_admitted

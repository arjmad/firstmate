#!/usr/bin/env bash
# Behavior tests for bin/fm-data-media-prune.sh: which torn-down, quiet tasks
# lose which media files, what always stays (text, finals, git checkouts,
# symlinks, live tasks), the dry-run listing, the opt-in config, and its seat
# among bin/fm-bootstrap.sh's locked MUTATING sweeps.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE="$ROOT/bin/fm-data-media-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-data-media-prune)
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# put <file> [content]: create a file and its parents.
put() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-x}" > "$1"
}

# make_task <home> <task>: a torn-down task's data directory, every file ten
# days old. clip.mp4, frames/frame-01.png, voice.WAV, and vm/disk.raw are
# prunable media;
# everything else is kept for a reason its name states.
make_task() {
  local d=$1/data/$2
  put "$d/brief.md" "# Task"
  put "$d/report.md" "Final cut: hero.mp4
The board showed clip.mp4 and frames/frame-01.png."
  put "$d/board/index.html" '<img src="../frames/frame-01.png"><video src="../clip.mp4">'
  put "$d/notes.txt"
  put "$d/clip.mp4"
  put "$d/frames/frame-01.png"
  put "$d/voice.WAV"
  put "$d/vm/disk.raw"
  put "$d/hero.mp4"
  put "$d/cut-FINAL.mov"
  put "$d/picks/finals.json" '["pick.jpg"]'
  put "$d/pick.jpg"
  put "$d/checkout/.git/HEAD" "ref: refs/heads/main"
  put "$d/checkout/asset.png"
  put "$TMP_ROOT/outside.png"
  ln -s "$TMP_ROOT/outside.png" "$d/link.png"
  find "$d" -type f -exec perl -e 'my $t = time - 10 * 86400; utime $t, $t, @ARGV' {} +
}

new_home() {  # <name>
  local h=$TMP_ROOT/$1/home
  mkdir -p "$h/state" "$h/data" "$h/config"
  printf '%s\n' "$h"
}

run_prune() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" bash "$PRUNE" "$@" 2>&1
}

PRUNABLE="clip.mp4 frames/frame-01.png voice.WAV vm/disk.raw"
KEPT="brief.md report.md board/index.html notes.txt hero.mp4 cut-FINAL.mov picks/finals.json pick.jpg checkout/.git/HEAD checkout/asset.png link.png"

assert_task_untouched() {  # <home> <task> <msg>
  local f
  for f in $PRUNABLE $KEPT; do
    [ -e "$1/data/$2/$f" ] || [ -L "$1/data/$2/$f" ] || fail "$3: $2/$f was removed"
  done
}

test_dry_run_lists_media_and_removes_nothing() {
  local home out
  home=$(new_home dry)
  make_task "$home" done-task
  out=$(run_prune "$home" --dry-run)
  assert_contains "$out" "would remove: 4 data/done-task/clip.mp4" "dry run lists a review render with its size"
  assert_contains "$out" "data/done-task/frames/frame-01.png" "dry run lists a nested frame"
  assert_contains "$out" "data/done-task/voice.WAV" "dry run matches extensions in any case"
  assert_equals 5 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "dry run prints four files and one summary"
  assert_contains "$out" "BOOTSTRAP_INFO: data media retention: would remove 4 files (0 MiB) from 1 torn-down tasks quiet over 7 days" \
    "dry run without config previews the 7-day default"
  assert_task_untouched "$home" done-task "dry run"
  pass "dry run: lists each prunable file with its size and removes nothing"
}

test_real_run_is_off_without_config() {
  local home out
  home=$(new_home off)
  make_task "$home" done-task
  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a home without config/data-media-retention-days must stay silent: $out"
  assert_task_untouched "$home" done-task "unconfigured real run"
  pass "opt-in: a real run without config removes nothing and prints nothing"
}

test_configured_run_removes_only_media_of_retired_quiet_tasks() {
  local home out f
  home=$(new_home real)
  printf '7\n' > "$home/config/data-media-retention-days"
  make_task "$home" done-task
  make_task "$home" live-task
  put "$home/state/live-task.meta" "window=x"
  local suffix
  for suffix in status inbox turn-ended backlog-close; do
    make_task "$home" "held-by-$suffix"
    put "$home/state/held-by-$suffix.$suffix"
  done
  make_task "$home" recent-task
  put "$home/data/recent-task/new-note.md"
  make_task "$home" no-brief
  rm "$home/data/no-brief/brief.md"
  mkdir -p "$TMP_ROOT/real/elsewhere"
  make_task "$TMP_ROOT/real/elsewhere" linked
  ln -s "$TMP_ROOT/real/elsewhere/data/linked" "$home/data/linked"

  out=$(run_prune "$home")
  assert_equals "BOOTSTRAP_INFO: data media retention: removed 4 files (0 MiB) from 1 torn-down tasks quiet over 7 days" \
    "$out" "a configured run reports one summary line"
  for f in $PRUNABLE; do
    assert_absent "$home/data/done-task/$f" "the retired, quiet task's $f should be removed"
  done
  for f in $KEPT; do
    [ -e "$home/data/done-task/$f" ] || [ -L "$home/data/done-task/$f" ] || fail "done-task/$f should be kept"
  done
  assert_present "$TMP_ROOT/outside.png" "a symlink's target outside data/ must survive"
  assert_task_untouched "$home" live-task "a task with a meta"
  for suffix in status inbox turn-ended backlog-close; do
    assert_task_untouched "$home" "held-by-$suffix" "a task with a $suffix record"
  done
  assert_task_untouched "$home" recent-task "a task with a file newer than the retention"
  for f in $PRUNABLE; do
    assert_present "$home/data/no-brief/$f" "a directory without brief.md must keep $f"
  done
  assert_task_untouched "$TMP_ROOT/real/elsewhere" linked "a symlinked task directory"

  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a converged home must stay silent: $out"
  pass "real run: removes only media of torn-down quiet tasks and keeps text, finals, checkouts, and live tasks"
}

test_days_option_and_bad_values() {
  local home out code
  home=$(new_home days)
  make_task "$home" done-task
  out=$(run_prune "$home" --dry-run --days 20)
  [ -z "$out" ] || fail "a task quiet for 10 days is inside a 20-day retention: $out"
  printf '20\n' > "$home/config/data-media-retention-days"
  out=$(run_prune "$home" --dry-run --days 5)
  assert_contains "$out" "quiet over 5 days" "--days overrides the config"
  for bad in 0 -3 7d ''; do
    printf '%s\n' "$bad" > "$home/config/data-media-retention-days"
    code=0
    out=$(run_prune "$home") || code=$?
    expect_code 2 "$code" "config value '$bad'"
  done
  code=0
  out=$(run_prune "$home" --days) || code=$?
  expect_code 2 "$code" "--days without a value"
  assert_task_untouched "$home" done-task "refused runs"
  pass "retention days: --days overrides config, and unusable values exit 2 without removing"
}

# --- bootstrap seat -----------------------------------------------------------

make_toolchain() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi gh tmux
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' '0.1.29'
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then printf '%s\n' 'Usage: treehouse get [--lease]'; fi
if [ "${1:-}" = lease ] && [ "${2:-}" = --help ]; then printf '%s\n' 'Usage: treehouse lease <name> [--lease-holder <holder>]'; fi
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
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_bootstrap_runs_prune_only_when_locked() {
  local home fb out f
  home=$(new_home boot)
  fb=$(make_toolchain "$TMP_ROOT/boot")
  printf 'tmux\n' > "$home/config/backend"
  printf '7\n' > "$home/config/data-media-retention-days"
  make_task "$home" done-task

  out=$(run_bootstrap "$fb" "$home" FM_BOOTSTRAP_DETECT_ONLY=1)
  assert_not_contains "$out" "data media retention" "the read-only session path must not prune"
  assert_task_untouched "$home" done-task "the read-only session path"

  out=$(run_bootstrap "$fb" "$home")
  assert_contains "$out" "BOOTSTRAP_INFO: data media retention: removed 4 files" \
    "the locked local pass should run the prune and relay its summary: $out"
  for f in $PRUNABLE; do
    assert_absent "$home/data/done-task/$f" "the locked pass should remove $f"
  done
  assert_present "$home/data/done-task/report.md" "the locked pass must keep the report"
  pass "bootstrap: the prune runs on the locked local pass only"
}

test_dry_run_lists_media_and_removes_nothing
test_real_run_is_off_without_config
test_configured_run_removes_only_media_of_retired_quiet_tasks
test_days_option_and_bad_values
test_bootstrap_runs_prune_only_when_locked

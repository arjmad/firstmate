#!/usr/bin/env bash
# Behavior tests for bin/fm-data-media-prune.sh: which torn-down, quiet tasks
# lose which media files, what always stays (text, finals, git checkouts,
# symlinks, live tasks, open backlog rows), the retention clock teardown has no
# timestamp for, the dry-run listing, the opt-in config and its limits, the
# separately opted-in scratch retention (clean pushed checkouts and dependency
# folders only), the data size trigger, and its seat among
# bin/fm-bootstrap.sh's locked MUTATING sweeps.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE="$ROOT/bin/fm-data-media-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-data-media-prune)
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# put <file> [content]: create a file and its parents.
put() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-x}" > "$1"
}

# backdate <days> <path>...: move each path's modification time <days> days back.
backdate() {
  local days=$1
  shift
  perl -e 'my $t = time - shift() * 86400; utime $t, $t, @ARGV or die "utime: $!\n"' "$days" "$@"
}

# make_task <home> <task>: a torn-down task's data directory, every file ten
# days old. The PRUNABLE files are review media; every KEPT file is kept for a
# reason its name or the report states.
make_task() {
  local d=$1/data/$2
  put "$d/brief.md" "# Task"
  put "$d/report.md" "# Report

Final cut: hero.mp4

The board showed clip.mp4 and frames/frame-01.png.

## Final renders

- out/Hero2.MP4

## Review

- frames/frame-01.png was rejected."
  put "$d/board/index.html" '<img src="../frames/frame-01.png"><video src="../clip.mp4">'
  put "$d/notes.txt"
  put "$d/clip.mp4"
  put "$d/frames/frame-01.png"
  put "$d/voice.WAV"
  put "$d/vm/disk.raw"
  put "$d/hero.mp4"
  put "$d/out/hero2.mp4"
  put "$d/cut-FINAL.mov"
  put "$d/picks/finals.json" '["pick.webm"]'
  put "$d/pick.webm"
  put "$d/checkout/.git/HEAD" "ref: refs/heads/main"
  put "$d/checkout/asset.mp4"
  put "$TMP_ROOT/outside.png"
  ln -s "$TMP_ROOT/outside.png" "$d/link.png"
  find "$d" -type f -exec perl -e 'my $t = time - 10 * 86400; utime $t, $t, @ARGV' {} +
}

# start_clock <home> <task> [days-ago]: the retention clock a first real run
# would have started, ten days ago unless told otherwise.
start_clock() {
  local clock=$1/state/data-media-retention/$2.retired
  mkdir -p "$(dirname "$clock")"
  : > "$clock"
  backdate "${3:-10}" "$clock"
}

# new_home <name> [backlog-row...]: a home whose markdown backlog holds the
# given open rows under Queued.
new_home() {
  local h=$TMP_ROOT/$1/home row
  shift
  mkdir -p "$h/state" "$h/data" "$h/config"
  {
    printf '## In flight\n\n## Queued\n'
    for row in "$@"; do printf '%s\n' "$row"; done
    printf '\n## Done\n- [x] done-task - Finished (repo: x) (kind: ship) (done 2026-10-01)\n'
  } > "$h/data/backlog.md"
  printf '%s\n' "$h"
}

run_prune() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" bash "$PRUNE" "$@" 2>&1
}

# run_media <home> [args...]: run_prune without the scratch part's own lines,
# which a dry run previews for every torn-down task.
run_media() {
  run_prune "$@" | grep -v '^data-scratch: ' || true
}

PRUNABLE="clip.mp4 voice.WAV vm/disk.raw"
KEPT="frames/frame-01.png brief.md report.md board/index.html notes.txt hero.mp4 out/hero2.mp4 cut-FINAL.mov picks/finals.json pick.webm checkout/.git/HEAD checkout/asset.mp4 link.png"

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
  out=$(run_media "$home" --dry-run)
  assert_equals "data media retention: would start the retention clock for 1 torn-down tasks" "$out" \
    "a dry run before any clock lists nothing and names the clock it would start"
  assert_absent "$home/state/data-media-retention" "a dry run must not start a clock"
  start_clock "$home" done-task
  out=$(run_media "$home" --dry-run)
  assert_contains "$out" "would remove: 4 data/done-task/clip.mp4" "dry run lists a review render with its size"
  assert_not_contains "$out" "frame-01.png" "still images are left to the Drive-move rule"
  assert_contains "$out" "data/done-task/voice.WAV" "dry run matches extensions in any case"
  assert_contains "$out" "data/done-task/vm/disk.raw" "dry run lists a VM disk"
  assert_equals 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "dry run prints three files and one summary"
  assert_contains "$out" "BOOTSTRAP_INFO: data media retention: would remove 3 files (0 MiB) from 1 torn-down tasks quiet over 7 days" \
    "dry run without config previews the 7-day default"
  assert_task_untouched "$home" done-task "dry run"
  pass "dry run: lists each prunable file with its size, starts no clock, and removes nothing"
}

test_real_run_is_off_without_config() {
  local home out
  home=$(new_home off)
  make_task "$home" done-task
  start_clock "$home" done-task
  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a home without config/data-media-retention-days must stay silent: $out"
  assert_task_untouched "$home" done-task "unconfigured real run"
  pass "opt-in: a real run without config removes nothing and prints nothing"
}

test_clock_starts_at_first_sight_of_teardown() {
  local home out f
  home=$(new_home clock)
  printf '7\n' > "$home/config/data-media-retention-days"
  make_task "$home" done-task
  out=$(run_prune "$home")
  [ -z "$out" ] || fail "the first run after teardown only starts the clock: $out"
  assert_present "$home/state/data-media-retention/done-task.retired" "the first real run starts the clock"
  assert_task_untouched "$home" done-task "a task whose clock just started"
  backdate 3 "$home/state/data-media-retention/done-task.retired"
  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a clock three days old is inside a 7-day retention: $out"
  backdate 8 "$home/state/data-media-retention/done-task.retired"
  out=$(run_prune "$home")
  assert_contains "$out" "removed 3 files" "a clock past the retention lets the prune run: $out"
  for f in $PRUNABLE; do
    assert_absent "$home/data/done-task/$f" "the torn-down, quiet task's $f should be removed"
  done
  pass "clock: retention counts from the first run that sees the task torn down, not from its last write"
}

test_configured_run_removes_only_media_of_retired_quiet_tasks() {
  local home out f suffix task
  home=$(new_home real \
    "- [ ] queued-task - Briefed, not spawned (repo: x) (kind: ship) (since 2026-10-01)" \
    "- [ ] held-task - Waiting on the captain (repo: x) (kind: scout) (since 2026-10-01) (hold: his call)")
  printf '7\n' > "$home/config/data-media-retention-days"
  for task in done-task live-task queued-task held-task recent-task no-brief; do
    make_task "$home" "$task"
    start_clock "$home" "$task"
  done
  put "$home/state/live-task.meta" "window=x"
  for suffix in status inbox turn-ended backlog-close; do
    make_task "$home" "held-by-$suffix"
    start_clock "$home" "held-by-$suffix"
    put "$home/state/held-by-$suffix.$suffix"
  done
  put "$home/data/recent-task/new-note.md"
  rm "$home/data/no-brief/brief.md"
  mkdir -p "$TMP_ROOT/real/elsewhere"
  make_task "$TMP_ROOT/real/elsewhere" linked
  ln -s "$TMP_ROOT/real/elsewhere/data/linked" "$home/data/linked"
  start_clock "$home" linked
  start_clock "$home" gone-task

  out=$(run_prune "$home")
  assert_equals "BOOTSTRAP_INFO: data media retention: removed 3 files (0 MiB) from 1 torn-down tasks quiet over 7 days" \
    "$out" "a configured run reports one summary line"
  for f in $PRUNABLE; do
    assert_absent "$home/data/done-task/$f" "the torn-down, quiet task's $f should be removed"
  done
  for f in $KEPT; do
    [ -e "$home/data/done-task/$f" ] || [ -L "$home/data/done-task/$f" ] || fail "done-task/$f should be kept"
  done
  assert_present "$TMP_ROOT/outside.png" "a symlink's target outside data/ must survive"
  assert_task_untouched "$home" live-task "a task with a meta"
  assert_absent "$home/state/data-media-retention/live-task.retired" "a live task loses its clock"
  for suffix in status inbox turn-ended backlog-close; do
    assert_task_untouched "$home" "held-by-$suffix" "a task with a $suffix record"
  done
  assert_task_untouched "$home" queued-task "a briefed task whose backlog row is still queued"
  assert_task_untouched "$home" held-task "a task whose backlog row holds an open captain call"
  assert_absent "$home/state/data-media-retention/held-task.retired" "an open backlog row clears the clock"
  assert_task_untouched "$home" recent-task "a task with a file newer than the retention"
  for f in $PRUNABLE; do
    assert_present "$home/data/no-brief/$f" "a directory without brief.md must keep $f"
  done
  assert_task_untouched "$TMP_ROOT/real/elsewhere" linked "a symlinked task directory"
  assert_absent "$home/state/data-media-retention/gone-task.retired" "a clock whose task directory is gone is removed"

  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a converged home must stay silent: $out"
  pass "real run: removes only media of torn-down quiet tasks and keeps text, finals, checkouts, live tasks, and open rows"
}

test_unreadable_backlog_removes_nothing() {
  local home out
  home=$(new_home nobacklog)
  printf '7\n' > "$home/config/data-media-retention-days"
  rm "$home/data/backlog.md"
  make_task "$home" done-task
  start_clock "$home" done-task
  out=$(run_prune "$home")
  assert_contains "$out" "warning: data media retention skipped: the backlog could not be read" \
    "a backlog that cannot be read is named"
  assert_task_untouched "$home" done-task "a run that cannot read the backlog"
  pass "fail closed: a backlog that cannot be read removes nothing"
}

test_days_option_and_bad_values() {
  local home out code bad
  home=$(new_home days)
  make_task "$home" done-task
  start_clock "$home" done-task
  out=$(run_media "$home" --dry-run --days 20)
  [ -z "$out" ] || fail "a task quiet for 10 days is inside a 20-day retention: $out"
  printf '20\n' > "$home/config/data-media-retention-days"
  out=$(run_media "$home" --dry-run --days 5)
  assert_contains "$out" "quiet over 5 days" "--days overrides the config"
  printf '07\n' > "$home/config/data-media-retention-days"
  out=$(run_media "$home" --dry-run)
  assert_contains "$out" "quiet over 7 days" "a leading zero reads as decimal"
  out=$(run_media "$home" --dry-run --days 3650)
  [ -z "$out" ] || fail "the longest retention keeps a 10-day-old task: $out"
  for bad in 0 00 -3 7d 3651 9999999999999999 ''; do
    printf '%s\n' "$bad" > "$home/config/data-media-retention-days"
    code=0
    out=$(run_prune "$home") || code=$?
    expect_code 2 "$code" "config value '$bad'"
  done
  code=0
  out=$(run_prune "$home" --days) || code=$?
  expect_code 2 "$code" "--days without a value"
  assert_task_untouched "$home" done-task "refused runs"
  pass "retention days: 1 to 3650 with --days over config, and anything else exits 2 without removing"
}

# --- scratch retention --------------------------------------------------------

fm_git_identity
ORIGIN="$TMP_ROOT/origin.git"
fm_git_init_commit "$TMP_ROOT/seed"
git clone -q --bare "$TMP_ROOT/seed" "$ORIGIN"

# make_scratch_task <home> <task>: a torn-down task holding a clean pushed
# clone and node_modules (scratch), work no remote holds in four shapes, and
# files every retention keeps; every file ten days old.
make_scratch_task() {
  local d=$1/data/$2 c
  put "$d/brief.md" "# Task"
  put "$d/report.md" "# Report"
  put "$d/shot.png"
  put "$d/out.pdf"
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000payload' > "$d/tool"
  put "$d/web/package.json" '{}'
  put "$d/web/node_modules/dep/index.js"
  for c in clean dirty untracked unpushed stashed; do
    mkdir -p "$d/clones"
    git clone -q "$ORIGIN" "$d/clones/$c"
  done
  printf 'edit\n' >> "$d/clones/dirty/README.md"
  put "$d/clones/untracked/new.txt"
  printf 'more\n' >> "$d/clones/unpushed/README.md"
  git -C "$d/clones/unpushed" commit -qam unpushed
  printf 'stash me\n' >> "$d/clones/stashed/README.md"
  git -C "$d/clones/stashed" stash -q
  find "$d" -type f -exec perl -e 'my $t = time - 10 * 86400; utime $t, $t, @ARGV' {} +
}

SCRATCH_GONE="clones/clean web/node_modules"
SCRATCH_KEPT="brief.md report.md shot.png out.pdf tool web/package.json clones/dirty/README.md
clones/untracked/new.txt clones/unpushed/README.md clones/stashed/README.md"

assert_scratch_untouched() {  # <home> <task> <msg>
  local f
  for f in $SCRATCH_GONE $SCRATCH_KEPT; do
    [ -e "$1/data/$2/$f" ] || fail "$3: $2/$f was removed"
  done
}

test_scratch_retention_is_its_own_opt_in() {
  local home out
  home=$(new_home scratch-off)
  make_scratch_task "$home" done-task
  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a home with no retention config must stay silent: $out"
  printf '7\n' > "$home/config/data-media-retention-days"
  start_clock "$home" done-task
  out=$(run_prune "$home")
  assert_not_contains "$out" "data scratch retention" "media retention alone must not start scratch retention"
  assert_scratch_untouched "$home" done-task "a home opted in to media retention only"
  pass "scratch retention: off without its own config, even where media retention is on"
}

test_scratch_dry_run_lists_and_removes_nothing() {
  local home out
  home=$(new_home scratch-dry)
  make_scratch_task "$home" done-task
  out=$(run_prune "$home" --dry-run)
  assert_contains "$out" "data-scratch: would remove checkout done-task/clones/clean (" "dry run names the clean clone"
  assert_contains "$out" "data-scratch: would remove node_modules done-task/web/node_modules (" "dry run names node_modules"
  assert_contains "$out" "data-scratch: kept checkout done-task/clones/dirty: uncommitted changes" "dry run names the dirty clone"
  assert_contains "$out" "data-scratch: kept checkout done-task/clones/untracked: uncommitted changes" "dry run names the untracked clone"
  assert_contains "$out" "data-scratch: kept checkout done-task/clones/unpushed: commits no remote-tracking branch holds" "dry run names the unpushed clone"
  assert_contains "$out" "data-scratch: kept checkout done-task/clones/stashed: a stash" "dry run names the stashed clone"
  assert_not_contains "$out" "binary" "scratch retention never removes a binary"
  assert_contains "$out" "BOOTSTRAP_INFO: data scratch retention: would remove 2 items (0 MiB) from 1 torn-down tasks quiet over 7 days" \
    "dry run without config previews the 7-day default"
  assert_scratch_untouched "$home" done-task "dry run"
  assert_absent "$home/state/data-media-retention" "a dry run must not start a clock"
  pass "scratch dry run: lists what would go and what stays, and removes nothing"
}

test_scratch_real_run_removes_only_clean_checkouts_and_dependency_folders() {
  local home out f task
  home=$(new_home scratch-real \
    "- [ ] queued-task - Briefed, not spawned (repo: x) (kind: ship) (since 2026-10-01)")
  printf '7\n' > "$home/config/data-scratch-retention-days"
  for task in done-task live-task queued-task recent-task; do
    make_scratch_task "$home" "$task"
  done
  put "$home/state/live-task.meta" "window=x"
  put "$home/data/recent-task/new-note.md"
  out=$(run_prune "$home")
  assert_equals "BOOTSTRAP_INFO: data scratch retention: removed 2 items (0 MiB) from 1 torn-down tasks quiet over 7 days" \
    "$out" "a configured run reports one summary line"
  for f in $SCRATCH_GONE; do
    assert_absent "$home/data/done-task/$f" "the torn-down, quiet task's $f should be removed"
  done
  for f in $SCRATCH_KEPT; do
    assert_present "$home/data/done-task/$f" "done-task/$f should be kept"
  done
  git -C "$home/data/done-task/clones/stashed" rev-parse -q --verify refs/stash >/dev/null \
    || fail "the stash must survive"
  assert_scratch_untouched "$home" live-task "a task with a meta"
  assert_scratch_untouched "$home" queued-task "a task whose backlog row is open"
  assert_scratch_untouched "$home" recent-task "a task with a file newer than the retention"
  assert_absent "$home/state/data-media-retention" "scratch retention starts no media clock"
  out=$(run_prune "$home")
  [ -z "$out" ] || fail "a converged home must stay silent: $out"
  out=$(run_prune "$home" --scratch-days 20)
  [ -z "$out" ] || fail "--scratch-days overrides the config: $out"
  local code=0
  run_prune "$home" --scratch-days 0 >/dev/null || code=$?
  expect_code 2 "$code" "--scratch-days 0"
  printf 'soon\n' > "$home/config/data-scratch-retention-days"
  code=0
  run_prune "$home" >/dev/null || code=$?
  expect_code 2 "$code" "a bad scratch config value"
  pass "scratch real run: only clean pushed checkouts and dependency folders of torn-down quiet tasks go"
}

# --- data size trigger ---------------------------------------------------------

mib() {  # <file> <MiB>: a file of exactly <MiB> MiB of real blocks
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null
}

test_size_trigger_names_the_largest_torn_down_tasks() {
  local home out
  home=$(new_home size)
  put "$home/data/big-task/brief.md" "# Task"
  mib "$home/data/big-task/web/node_modules/dep/blob" 2
  put "$home/data/big-task/web/package.json" '{}'
  mib "$home/data/big-task/shots/screen.png" 1
  mib "$home/data/big-task/out.pdf" 1
  mib "$home/data/big-task/export.csv" 1
  put "$home/data/small-task/brief.md" "# Task"
  mib "$home/data/small-task/notes.bin" 1
  put "$home/data/live-task/brief.md" "# Task"
  mib "$home/data/live-task/huge.bin" 4
  put "$home/state/live-task.meta" "window=x"

  out=$(run_prune "$home")
  [ -z "$out" ] || fail "data/ under the default trigger must stay silent: $out"

  printf '1\n' > "$home/config/data-size-trigger-mib"
  out=$(run_prune "$home")
  assert_contains "$out" "BOOTSTRAP_INFO: data size: data/ holds " "the trigger names data/'s size"
  assert_contains "$out" ", over the 1 MiB trigger; its largest torn-down tasks follow." "the trigger names itself"
  assert_contains "$out" "images and PDFs move to Drive only as one captain-approved batch (docs/configuration.md)" \
    "the trigger names the Drive rule for images and PDFs"
  assert_contains "$out" "BOOTSTRAP_INFO: data size: big-task 5 MiB: 0 MiB clean checkouts, 2 MiB dependency folders, 1 MiB images, 1 MiB PDFs, 1 MiB other" \
    "the largest task's line says what it holds"
  assert_contains "$out" "BOOTSTRAP_INFO: data size: small-task 1 MiB: " "the next task follows"
  assert_not_contains "$out" "live-task" "a live task is not a torn-down task"
  [ "$(printf '%s\n' "$out" | grep -n 'big-task' | cut -d: -f1)" -lt "$(printf '%s\n' "$out" | grep -n 'small-task' | cut -d: -f1)" ] \
    || fail "the largest task comes first: $out"
  assert_present "$home/data/big-task/web/node_modules/dep/blob" "the size trigger removes nothing"
  out=$(run_prune "$home" --dry-run | grep -v '^data-scratch: ')
  assert_contains "$out" "BOOTSTRAP_INFO: data size: big-task 5 MiB" "a dry run reports the trigger too"

  rm "$home/data/backlog.md"
  out=$(run_prune "$home")
  assert_contains "$out" "over the 1 MiB trigger; torn-down tasks are unknown because the backlog could not be read" \
    "a backlog that cannot be read still reports the size"
  for bad in 0 lots 16777217; do
    printf '%s\n' "$bad" > "$home/config/data-size-trigger-mib"
    code=0
    run_prune "$home" >/dev/null || code=$?
    expect_code 2 "$code" "size trigger value '$bad'"
  done
  pass "size trigger: over the configured size, names the largest torn-down tasks and what each holds, and removes nothing"
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
  # tasks-axi answers the version probes and lists an empty backlog.
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
  "list "*) printf '%s\n' 'count: 0' 'tasks: 0 tasks in this backlog' ;;
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
  start_clock "$home" done-task

  out=$(run_bootstrap "$fb" "$home" FM_BOOTSTRAP_DETECT_ONLY=1)
  assert_not_contains "$out" "data media retention" "the read-only session path must not prune"
  assert_task_untouched "$home" done-task "the read-only session path"

  out=$(run_bootstrap "$fb" "$home")
  assert_contains "$out" "BOOTSTRAP_INFO: data media retention: removed 3 files" \
    "the locked local pass should run the prune and relay its summary: $out"
  for f in $PRUNABLE; do
    assert_absent "$home/data/done-task/$f" "the locked pass should remove $f"
  done
  assert_present "$home/data/done-task/report.md" "the locked pass must keep the report"
  pass "bootstrap: the prune runs on the locked local pass only"
}

test_dry_run_lists_media_and_removes_nothing
test_real_run_is_off_without_config
test_clock_starts_at_first_sight_of_teardown
test_configured_run_removes_only_media_of_retired_quiet_tasks
test_unreadable_backlog_removes_nothing
test_days_option_and_bad_values
test_scratch_retention_is_its_own_opt_in
test_scratch_dry_run_lists_and_removes_nothing
test_scratch_real_run_removes_only_clean_checkouts_and_dependency_folders
test_size_trigger_names_the_largest_torn_down_tasks
test_bootstrap_runs_prune_only_when_locked

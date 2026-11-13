#!/usr/bin/env bash
# Behavior tests for bin/fm-tasks-axi.sh home addressing and bootstrap's
# shadow-backlog check, over the split layout where the operational home lives
# outside the code root that carries the tracked .tasks.toml.
#
# The fork these guard against: .tasks.toml names data/backlog.md relative to
# the caller's working directory, and tasks-axi writes by renaming a temp file
# over its target, so a bare tasks-axi run from the code root turns a code-root
# symlink into the home's backlog into a private regular copy. The suite proves
# that every write through bin/fm-tasks-axi.sh lands in $FM_HOME/data from the
# code root (including archiving and relative --body-file arguments),
# that the command refuses addressing it cannot keep correct, and that bootstrap
# reports any code-root copy that is not this home's own file while staying
# silent for a link into the home, an absent copy, and the single-home layout.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The developer shell may pin any of these; each case states its own layout.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A code root carrying the tracked .tasks.toml and an operational home beside
# it, with the code-root backlog linked into the home the way an operator
# would try to keep the two in sync.
make_split() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  fm_test_tasks_toml "$dir/code/.tasks.toml"
  empty_backlog "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

# Run the wrapper from the code root, as firstmate does.
wrapper_from_code() {  # <case-dir> <tasks-axi args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

# Only the shadow-backlog lines matter here; the rest of a detect-only local
# bootstrap pass reports this host's toolchain, which is not under test, so it
# runs on the bare base PATH where every tool probe is a fast miss.
bootstrap_backlog_lines() {  # <code-root> [<home>]
  local code=$1 home=${2:-}
  if [ -n "$home" ]; then
    PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  else
    PATH="$BASE_PATH" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  fi
}

test_guard_reports_regular_code_root_backlog() {
  local dir out
  dir=$(make_split guard-regular)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "a code-root link into this home must stay silent"

  rm "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "an absent code-root backlog must stay silent"

  printf '## In flight\n\n## Queued\n\n- [ ] stray: written from the code root\n\n## Done\n' \
    > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "BACKLOG_RECONCILE: code-root $dir/code/data/backlog.md is not this home's $dir/home/data/backlog.md" \
    "a regular code-root backlog beside a separate home was not reported"
  assert_not_contains "$out" "done-archive.md" "an absent code-root archive was reported"
  pass "bootstrap reports a regular code-root backlog and stays silent for a link into the home or no copy"
}

test_guard_reports_foreign_link_and_archive() {
  local dir out
  dir=$(make_split guard-foreign)
  empty_backlog "$dir/elsewhere.md"
  rm "$dir/code/data/backlog.md"
  ln -s "$dir/elsewhere.md" "$dir/code/data/backlog.md"
  printf '## Done\n' > "$dir/code/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
    "a code-root backlog linked outside this home was not reported"
  assert_contains "$out" "code-root $dir/code/data/done-archive.md is not this home's $dir/home/data/done-archive.md" \
    "a regular code-root archive beside a separate home was not reported"
  pass "bootstrap reports a code-root backlog linked elsewhere and a forked archive"
}

test_guard_silent_for_single_home() {
  local dir out
  dir="$TMP_ROOT/single-guard"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  printf '## Done\n' > "$dir/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir")
  assert_equals "" "$out" "the single-home layout's own backlog was reported as a fork"
  out=$(bootstrap_backlog_lines "$dir" "$dir")
  assert_equals "" "$out" "FM_HOME naming the code root was reported as a fork"
  pass "bootstrap stays silent when the code root is the home"
}

# The end-to-end fork: a bare tasks-axi write from the code root. Whatever the
# installed tasks-axi does to the link, bootstrap must agree with the result:
# a replaced link is reported, a written-through link is not.
test_bare_tasks_axi_fork_is_detected() {
  local dir out
  dir=$(make_split bare-fork)
  (cd "$dir/code" && tasks-axi add bare-1 "written from the code root" >/dev/null 2>&1) \
    || fail "bare tasks-axi add failed in the code root"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  if [ -L "$dir/code/data/backlog.md" ]; then
    assert_grep "bare-1" "$dir/home/data/backlog.md" "a written-through link lost the row"
    assert_equals "" "$out" "a written-through link was reported as a fork"
    pass "bare tasks-axi wrote through the code-root link and bootstrap stayed silent"
  else
    assert_no_grep "bare-1" "$dir/home/data/backlog.md" "the replaced link still reached the home"
    assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
      "bootstrap missed the fork a bare tasks-axi write left behind"
    pass "bare tasks-axi replaced the code-root link and bootstrap reported the fork"
  fi
}

test_wrapper_writes_through_to_home() {
  local dir i
  dir=$(make_split wrapper-home)
  for i in 1 2; do
    wrapper_from_code "$dir" add "ship-$i" "ship $i" >/dev/null || fail "add ship-$i failed"
    wrapper_from_code "$dir" start "ship-$i" >/dev/null || fail "start ship-$i failed"
    wrapper_from_code "$dir" "done" "ship-$i" >/dev/null || fail "done ship-$i failed"
  done
  wrapper_from_code "$dir" add call-1 "captain call" >/dev/null || fail "add call-1 failed"
  wrapper_from_code "$dir" hold call-1 --reason "awaiting the captain" --kind captain --until 2030-01-01 >/dev/null \
    || fail "hold call-1 failed"
  printf 'RELATIVE-BODY-MARKER\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" update call-1 --body-file body.md >/dev/null \
    || fail "update with a caller-relative --body-file failed"
  wrapper_from_code "$dir" prune --keep 1 >/dev/null || fail "prune failed"

  [ -L "$dir/code/data/backlog.md" ] || fail "a wrapper write replaced the code-root link"
  [ "$dir/code/data/backlog.md" -ef "$dir/home/data/backlog.md" ] \
    || fail "the code-root link no longer names the home's backlog"
  assert_grep "call-1" "$dir/home/data/backlog.md" "the held row did not land in the home"
  assert_grep "RELATIVE-BODY-MARKER" "$dir/home/data/backlog.md" \
    "a caller-relative --body-file was not read from the caller's directory"
  assert_present "$dir/home/data/done-archive.md" "archiving did not reach the home"
  assert_grep "ship-1" "$dir/home/data/done-archive.md" "the oldest closed row was not archived in the home"
  assert_absent "$dir/code/data/done-archive.md" "archiving wrote a code-root archive"
  assert_equals "" "$(bootstrap_backlog_lines "$dir/code" "$dir/home")" \
    "bootstrap reported a fork after only wrapper writes"
  pass "fm-tasks-axi.sh writes, holds, archives, and reads relative body files through to the home from the code root"
}

test_wrapper_overrides_ambient_file() {
  local dir
  dir=$(make_split wrapper-ambient)
  empty_backlog "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" "$WRAPPER" add amb-1 "ambient" >/dev/null) \
    || fail "add under an ambient TASKS_AXI_FILE failed"
  assert_grep "amb-1" "$dir/home/data/backlog.md" "an ambient TASKS_AXI_FILE diverted the write from the home"
  assert_no_grep "amb-1" "$dir/decoy.md" "an ambient TASKS_AXI_FILE received the write"
  wrapper_from_code "$dir" >/dev/null || fail "the no-command dashboard failed"
  pass "fm-tasks-axi.sh pins the home's backlog over an ambient TASKS_AXI_FILE and serves the dashboard"
}

test_wrapper_refusals() {
  local dir out rc before
  dir=$(make_split wrapper-refuse)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add r-1 "explicit" --file "$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file"
  assert_contains "$out" "drop --file" "--file refusal did not explain itself"
  out=$(wrapper_from_code "$dir" list --file="$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file="

  mv "$dir/home/data/backlog.md" "$dir/home/real-backlog.md"
  ln -s "$dir/home/real-backlog.md" "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add r-2 "through a link" 2>&1)
  rc=$?
  expect_code 2 "$rc" "symlinked home backlog"
  assert_contains "$out" "is a symlink" "the symlinked home backlog refusal did not name the link"
  [ -L "$dir/home/data/backlog.md" ] || fail "a refused call still replaced the home link"
  assert_equals "$before" "$(cat "$dir/home/real-backlog.md")" "a refused call changed the backlog"

  out=$(cd "$dir/code" && FM_HOME="$dir/missing-home" "$WRAPPER" list 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing data directory"
  pass "fm-tasks-axi.sh refuses caller --file, a symlinked home backlog, and an unresolvable home"
}

# Dispatch alone moves a row to In flight, because only bin/fm-spawn.sh
# creates the task record, status file, and inbox that go with it; a row
# hand-placed there through `add --start` would count as live work nobody runs.
test_wrapper_refuses_add_start() {
  local dir out rc before
  dir=$(make_split wrapper-add-start)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add hs-1 "hand-started" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the add --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add --start still wrote a row"
  out=$(wrapper_from_code "$dir" create hs-c "hand-started via alias" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "create --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the create --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused create --start still wrote a row"
  wrapper_from_code "$dir" add hs-2 "queued" >/dev/null || fail "plain add was refused"
  assert_grep "hs-2" "$dir/home/data/backlog.md" "plain add did not write its row"
  wrapper_from_code "$dir" start hs-2 >/dev/null || fail "start <id> was refused"
  pass "fm-tasks-axi.sh refuses add --start while plain add and start <id> pass through"
}

# Every row added names its owner (bin/fm-backlog-owner-lib.sh): the kind's
# default, fleet, unless --owner or the body's own Owner: line names one; a
# kind=captain row must name one. A body rewrite keeps the recorded owner, and
# `owner` reads and records it.
test_wrapper_owner_at_filing() {
  local dir out rc before body
  dir=$(make_split wrapper-owner)
  wrapper_from_code "$dir" add ow-ship "fleet work" --kind ship >/dev/null || fail "plain add was refused"
  assert_equals fleet "$(wrapper_from_code "$dir" owner ow-ship)" "a ship row did not default to the fleet"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add ow-cap "his call" --kind captain 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --kind captain without --owner"
  assert_contains "$out" "must name its owner" "the captain-kind refusal did not say why"
  out=$(wrapper_from_code "$dir" add ow-bad "bad owner" --owner=captain 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --owner captain"
  out=$(wrapper_from_code "$dir" add ow-none "no value" --owner 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --owner with no value"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add still wrote a row"
  wrapper_from_code "$dir" create ow-cap "his call" --kind captain --owner arjun --body "keep or undo" >/dev/null \
    || fail "add --owner arjun was refused"
  assert_equals arjun "$(wrapper_from_code "$dir" owner ow-cap)" "--owner arjun was not recorded"
  printf 'first line\n\nOwner: arjun\n' > "$dir/body.md"
  (cd "$dir" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" add ow-file "from a file" --kind captain --body-file body.md >/dev/null) \
    || fail "a body naming its owner was refused"
  assert_equals arjun "$(wrapper_from_code "$dir" owner ow-file)" "the body's own owner line was not honored"
  wrapper_from_code "$dir" update ow-cap --body "rewritten note" >/dev/null || fail "update --body failed"
  assert_equals arjun "$(wrapper_from_code "$dir" owner ow-cap)" "a body rewrite dropped the owner"
  printf 'piped note\n' | wrapper_from_code "$dir" update ow-file --body-file - >/dev/null || fail "update --body-file - failed"
  assert_equals arjun "$(wrapper_from_code "$dir" owner ow-file)" "a piped body rewrite dropped the owner"
  body=$(wrapper_from_code "$dir" show ow-file --full)
  assert_contains "$body" "piped note" "the piped body was not written"
  out=$(wrapper_from_code "$dir" owner ow-cap fleet)
  assert_contains "$out" "ow-cap -> fleet" "owner did not record the change"
  out=$(wrapper_from_code "$dir" owner ow-cap fleet)
  assert_contains "$out" "already fleet" "a repeated owner was not a no-op"
  [ "$(grep -c '^  Owner: ' "$dir/home/data/backlog.md")" = 3 ] \
    || fail "rows do not carry exactly one owner line each: $(cat "$dir/home/data/backlog.md")"
  out=$(wrapper_from_code "$dir" owner ow-missing 2>&1)
  rc=$?
  expect_code 2 "$rc" "owner on a missing row"
  out=$(wrapper_from_code "$dir" owner ow-cap boss 2>&1)
  rc=$?
  expect_code 2 "$rc" "owner with an unknown value"
  out=$(wrapper_from_code "$dir" update --body "id last" ow-cap 2>&1)
  rc=$?
  expect_code 2 "$rc" "update with the row id after the body"
  wrapper_from_code "$dir" hold ow-file --reason "his call" --kind captain --until 2030-01-01 >/dev/null || fail "could not hold ow-file"
  out=$(wrapper_from_code "$dir" owner ow-file fleet 2>&1)
  rc=$?
  expect_code 2 "$rc" "owner fleet on a captain-held row"
  assert_contains "$out" "held for the captain" "the captain-hold refusal did not say why"
  assert_equals arjun "$(wrapper_from_code "$dir" owner ow-file)" "a refused owner change still wrote"
  printf 'his words:\nOwner: fleet\n\nOwner: fleet\n' > "$dir/fleet-body.md"
  out=$(wrapper_from_code "$dir" update ow-file --body-file "$dir/fleet-body.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "an update body naming the fleet on a captain-held row"
  wrapper_from_code "$dir" hold ow-cap --reason "his old call" --kind captain --until 2020-01-01 >/dev/null \
    || fail "could not hold ow-cap with a past date"
  out=$(wrapper_from_code "$dir" owner ow-cap fleet 2>&1)
  rc=$?
  expect_code 2 "$rc" "owner fleet on a captain hold whose date has passed"
  wrapper_from_code "$dir" add ow-quote "quoted words" --kind ship \
    --body "$(printf 'Captain said:\nOwner: arjun\n\nOwner: fleet')" >/dev/null || fail "could not add ow-quote"
  wrapper_from_code "$dir" owner ow-quote arjun >/dev/null || fail "could not record arjun on ow-quote"
  body=$(wrapper_from_code "$dir" show ow-quote --full)
  assert_contains "$body" 'Captain said:\nOwner: arjun\n\nOwner: arjun' "an owner rewrite did not keep the quoted line and replace only its own"
  [ -z "$(find "$dir/home/state" -name '.control-*.lock' 2>/dev/null)" ] \
    || fail "an owner write left its control lock behind"
  pass "fm-tasks-axi.sh names every new row's owner, keeps it through body rewrites, and reads and records it"
}

test_wrapper_single_home() {
  local dir
  dir="$TMP_ROOT/single-wrapper"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

# The opt-in superseded-ruling guard: with config/captain-name present, a hold
# or park whose reason re-cites an older dated captain quote than the newest
# one in the task's row, brief, or handled steers is refused unless the caller
# passes --cite-older-quote; with the file absent nothing is checked.
test_wrapper_hold_quote_guard() {
  local dir out rc before
  dir=$(make_split hold-quote)
  mkdir -p "$dir/home/data/q-1" "$dir/home/state/q-1.inbox/handled"
  wrapper_from_code "$dir" add q-1 "proxmox host" >/dev/null || fail "add q-1 failed"
  printf 'Arjun 2026-10-05: keep the host running\n' > "$dir/home/state/q-1.inbox/handled/001.msg"
  printf '## Progress note (2026-12-01T10:00:00Z)\nArjunx 2026-12-02 is not the captain\n' \
    > "$dir/home/data/q-1/brief.md"

  wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 --reason "Arjun 2026-09-30: park it" >/dev/null \
    || fail "a hold was refused with no config/captain-name"
  wrapper_from_code "$dir" unhold q-1 >/dev/null || fail "unhold q-1 failed"

  printf '# the captain\n\nArjun\n' > "$dir/home/config/captain-name"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 --reason "Arjun 2026-09-30: park it" 2>&1)
  rc=$?
  expect_code 2 "$rc" "older quote than a handled steer"
  assert_contains "$out" "dated 2026-09-30" "the refusal did not name the cited date"
  assert_contains "$out" "is 2026-10-05 (in $dir/home/state/q-1.inbox/handled/001.msg)" \
    "the refusal did not name the newest quote and its source"
  assert_contains "$out" "--cite-older-quote" "the refusal did not name the override"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused hold changed the backlog"
  out=$(wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 "--reason=Arjun, 2026-09-30: park it" 2>&1)
  rc=$?
  expect_code 2 "$rc" "older quote through --reason="

  wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 --reason "Arjun 2026-09-30: park it" --cite-older-quote >/dev/null \
    || fail "--cite-older-quote did not let the older quote stand"
  assert_grep "Arjun 2026-09-30: park it" "$dir/home/data/backlog.md" "the overridden hold was not recorded"
  wrapper_from_code "$dir" unhold q-1 >/dev/null || fail "unhold q-1 failed"
  wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 --reason "Arjun 2026-10-05: wait for the window" >/dev/null \
    || fail "a hold citing the newest quote was refused"
  wrapper_from_code "$dir" unhold q-1 >/dev/null || fail "unhold q-1 failed"
  wrapper_from_code "$dir" hold q-1 --kind future --until 2030-01-01 --reason "waiting on a free slot" >/dev/null \
    || fail "a hold citing no captain quote was refused"
  wrapper_from_code "$dir" unhold q-1 >/dev/null || fail "unhold q-1 failed"

  printf 'Captain ruling, Arjun on 2026-10-07: retire it\n' >> "$dir/home/data/q-1/brief.md"
  out=$(wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 --reason "Arjun 2026-10-05: wait for the window" 2>&1)
  rc=$?
  expect_code 2 "$rc" "older quote than the brief"
  assert_contains "$out" "is 2026-10-07 (in $dir/home/data/q-1/brief.md)" "the brief's quote was not found"

  printf 'Arjun 2026-10-08: decided in chat\n' > "$dir/body.md"
  wrapper_from_code "$dir" update q-1 --body-file "$dir/body.md" >/dev/null || fail "update q-1 failed"
  out=$(wrapper_from_code "$dir" hold q-1 --kind parked --until 2030-01-01 --reason "Arjun 2026-10-07: retire it" 2>&1)
  rc=$?
  expect_code 2 "$rc" "older quote than the row"
  assert_contains "$out" "is 2026-10-08 (in its backlog row)" "the row's quote was not found"
  pass "fm-tasks-axi.sh refuses a hold citing an older captain quote only when config/captain-name is set, unless overridden"
}

# Row shape (bin/fm-backlog-row-lib.sh): strict hold kinds with their dates,
# no dates in titles, and Due: and Batch: lines that survive a body rewrite.
test_wrapper_row_shape() {
  local dir out rc body
  dir=$(make_split row-shape)

  out=$(wrapper_from_code "$dir" add rs-dated "[2026-11-09] call the vendor" 2>&1)
  rc=$?
  expect_code 2 "$rc" "add with a dated title"
  assert_contains "$out" "not a date" "the dated-title refusal did not say why"
  assert_no_grep "rs-dated" "$dir/home/data/backlog.md" "a refused dated title was still added"

  wrapper_from_code "$dir" add rs-1 "Call the vendor" --due 2026-11-20 --batch office --body "first note" >/dev/null \
    || fail "add with --due and --batch failed"
  assert_equals 2026-11-20 "$(wrapper_from_code "$dir" due rs-1)" "add --due was not recorded"
  assert_equals office "$(wrapper_from_code "$dir" batch rs-1)" "add --batch was not recorded"
  assert_equals fleet "$(wrapper_from_code "$dir" owner rs-1)" "the owner was not recorded beside the row fields"
  body=$(wrapper_from_code "$dir" show rs-1 --full)
  assert_contains "$body" 'first note\n\nDue: 2026-11-20\nBatch: office\n\nOwner: fleet' "the row fields are not one block above the owner"

  out=$(wrapper_from_code "$dir" update rs-1 --title "[2026-11-01] call the vendor" 2>&1)
  rc=$?
  expect_code 2 "$rc" "update with a dated title"

  wrapper_from_code "$dir" update rs-1 --body "second note" >/dev/null || fail "update --body failed"
  assert_equals 2026-11-20 "$(wrapper_from_code "$dir" due rs-1)" "a body rewrite dropped the due date"
  assert_equals office "$(wrapper_from_code "$dir" batch rs-1)" "a body rewrite dropped the batch tag"
  assert_equals fleet "$(wrapper_from_code "$dir" owner rs-1)" "a body rewrite dropped the owner"

  out=$(wrapper_from_code "$dir" due rs-1 2026-12-01) || fail "due could not change the date"
  assert_contains "$out" "rs-1 -> 2026-12-01" "due did not report the change"
  out=$(wrapper_from_code "$dir" due rs-1 2026-12-01)
  assert_contains "$out" "already 2026-12-01" "a repeated due was not a no-op"
  wrapper_from_code "$dir" batch rs-1 - >/dev/null || fail "batch could not clear the tag"
  assert_equals - "$(wrapper_from_code "$dir" batch rs-1)" "a cleared batch tag is still recorded"
  [ "$(grep -c '^  Due: ' "$dir/home/data/backlog.md")" = 1 ] \
    || fail "the row does not carry exactly one due line: $(cat "$dir/home/data/backlog.md")"
  out=$(wrapper_from_code "$dir" due rs-1 2026-02-30 2>&1)
  rc=$?
  expect_code 2 "$rc" "due with an impossible date"
  out=$(wrapper_from_code "$dir" batch rs-1 Office 2>&1)
  rc=$?
  expect_code 2 "$rc" "batch with an uppercase tag"
  # A group names itself by structured fields: a place list or a board.
  wrapper_from_code "$dir" batch rs-1 place:office >/dev/null || fail "batch refused a place tag"
  assert_equals place:office "$(wrapper_from_code "$dir" batch rs-1)" "a place tag was not recorded"
  wrapper_from_code "$dir" batch rs-1 board:pricing-review.1111 >/dev/null || fail "batch refused a board tag"
  assert_equals board:pricing-review.1111 "$(wrapper_from_code "$dir" batch rs-1)" "a board tag was not recorded"
  for bad in place:Office shelf:office board: place:a.b; do
    out=$(wrapper_from_code "$dir" batch rs-1 "$bad" 2>&1)
    rc=$?
    expect_code 2 "$rc" "batch with the tag $bad"
  done
  wrapper_from_code "$dir" batch rs-1 - >/dev/null || fail "batch could not clear a board tag"
  out=$(wrapper_from_code "$dir" due rs-missing 2026-12-01 2>&1)
  rc=$?
  expect_code 2 "$rc" "due on a missing row"
  out=$(wrapper_from_code "$dir" add rs-bad "Bad due" --due 2026-13-01 2>&1)
  rc=$?
  expect_code 2 "$rc" "add with an invalid --due"

  wrapper_from_code "$dir" due rs-1 - >/dev/null || fail "due could not clear the date"
  out=$(wrapper_from_code "$dir" hold rs-1 --reason "waiting" --until 2026-12-01 2>&1)
  rc=$?
  expect_code 2 "$rc" "hold without a kind"
  out=$(wrapper_from_code "$dir" hold rs-1 --reason "waiting" --kind load --until 2026-12-01 2>&1)
  rc=$?
  expect_code 2 "$rc" "hold of a kind outside the four"
  for kind in future parked; do
    out=$(wrapper_from_code "$dir" hold rs-1 --reason "waiting" --kind "$kind" 2>&1)
    rc=$?
    expect_code 2 "$rc" "a $kind hold without a date"
    assert_contains "$out" "back-on date" "the undated $kind refusal did not ask for its back-on date"
  done
  out=$(wrapper_from_code "$dir" hold rs-1 --reason "vendor reply" --kind external 2>&1)
  rc=$?
  expect_code 2 "$rc" "an external wait without a date"
  assert_contains "$out" "recheck date" "the undated external refusal did not ask for a recheck date"
  out=$(wrapper_from_code "$dir" hold rs-1 --reason "vendor reply" --kind external --until 2026-11-31 2>&1)
  rc=$?
  expect_code 2 "$rc" "an external wait with an impossible date"
  assert_no_grep "hold-kind" "$dir/home/data/backlog.md" "a refused hold still wrote"
  wrapper_from_code "$dir" hold rs-1 --reason "vendor reply" --kind external --until 2026-11-12 >/dev/null \
    || fail "a dated external wait was refused"
  assert_grep "(hold-kind: external) (hold-until: 2026-11-12)" "$dir/home/data/backlog.md" \
    "the external wait did not record its recheck date"
  wrapper_from_code "$dir" add rs-due "File the return" --due 2026-12-15 >/dev/null || fail "could not add rs-due"
  out=$(wrapper_from_code "$dir" hold rs-due --reason "after the season" --kind future 2>&1)
  rc=$?
  expect_code 2 "$rc" "a future hold with only a due date, which nothing would lift"
  wrapper_from_code "$dir" hold rs-due --reason "his call" --kind captain >/dev/null \
    || fail "a captain hold on a row with a recorded due date was refused"
  out=$(wrapper_from_code "$dir" hold --help 2>&1) || fail "hold --help was refused: $out"
  assert_not_contains "$out" "a hold needs" "hold --help ran the hold refusals"
  out=$(wrapper_from_code "$dir" hold rs-1 --reason "his call" --kind captain 2>&1)
  rc=$?
  expect_code 2 "$rc" "an undated captain hold through the wrapper"
  assert_contains "$out" "fm-captain-hold.sh hold" "the undated captain refusal did not name the captain-hold path"
  pass "fm-tasks-axi.sh keeps dates out of titles, holds to the four kinds with their dates, and keeps Due: and Batch: lines"
}

# A handoff row's close answers its handoff note (request id handoff:<id>) when
# nobody replied by hand: done carries the close's links, rm carries --reason,
# a row with no handoff note is untouched, and a reply already written stands.
test_wrapper_close_writes_handoff_reply() {
  local dir out note1 note2 note3 receipts
  dir=$(make_split close-reply)
  fm_test_tasks_toml "$dir/home/.tasks.toml"
  inbox() { FM_HOME="$dir/home" "$ROOT/bin/fm-inbox.sh" "$@"; }
  note_of() { python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
  reply_of() {  # <note-id>
    inbox receipts --all-pending --all-handled --all-replies | python3 -c '
import json, sys
d = json.load(sys.stdin)
for n in d["pending"] + d["handled"]:
    if n["id"] == sys.argv[1]:
        print((n.get("reply") or {}).get("body") or "NO-REPLY")' "$1"
  }
  for id in hf-done hf-rm hf-plain hf-answered; do
    wrapper_from_code "$dir" add "$id" "Handoff $id" --kind task >/dev/null || fail "could not add $id"
  done
  note1=$(inbox note --request-id handoff:hf-done --json "[claude] handoff hf-done" | note_of)
  note2=$(inbox note --request-id handoff:hf-rm --json "[claude] handoff hf-rm" | note_of)
  note3=$(inbox note --request-id handoff:hf-answered --json "[claude] handoff hf-answered" | note_of)
  inbox drain --ack "$note1" >/dev/null
  inbox reply "$note3" "Answered by hand first" >/dev/null || fail "hand reply failed"

  out=$(wrapper_from_code "$dir" "done" hf-done --pr https://github.com/o/r/pull/7 --json 2>/dev/null) \
    || fail "done hf-done failed"
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || fail "done --json stdout is no longer plain JSON: $out"
  receipts=$(reply_of "$note1")
  assert_contains "$receipts" "Done: firstmate closed backlog item hf-done" "done did not write the handoff reply"
  assert_contains "$receipts" "PR: https://github.com/o/r/pull/7" "the done reply lost the PR link"

  wrapper_from_code "$dir" rm hf-rm --reason "duplicate of hf-done" >/dev/null 2>&1 || fail "rm hf-rm failed"
  receipts=$(reply_of "$note2")
  assert_contains "$receipts" "Removed: firstmate took backlog item hf-rm off its backlog" "rm did not write the handoff reply"
  assert_contains "$receipts" "Reason: duplicate of hf-done" "the rm reply lost the reason"
  assert_no_grep "hf-rm" "$dir/home/data/backlog.md" "rm --reason did not remove the row"

  out=$(wrapper_from_code "$dir" "done" hf-plain 2>&1) || fail "done hf-plain failed: $out"
  assert_not_contains "$out" "replied" "a row with no handoff note got a reply"
  assert_not_contains "$out" "not written" "a row with no handoff note warned"

  wrapper_from_code "$dir" add hf-help "Handoff hf-help" --kind task >/dev/null || fail "could not add hf-help"
  inbox note --request-id handoff:hf-help --json "[claude] handoff hf-help" >/dev/null
  wrapper_from_code "$dir" "done" hf-help --help >/dev/null 2>&1 || fail "done --help failed"
  [ ! -d "$dir/home/state/inbox/.replies" ] || [ -z "$(grep -l '^Done: .*hf-help' "$dir/home/state/inbox/.replies"/* 2>/dev/null)" ] \
    || fail "a help read wrote the handoff reply while the row stays open"

  wrapper_from_code "$dir" "done" hf-answered >/dev/null 2>&1 || fail "done hf-answered failed"
  assert_equals "Answered by hand first" "$(reply_of "$note3")" "the close overwrote a reply written by hand"
  pass "fm-tasks-axi.sh done and rm answer a handoff note nobody answered, and leave others alone"
}

test_guard_reports_regular_code_root_backlog
test_guard_reports_foreign_link_and_archive
test_guard_silent_for_single_home
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_bare_tasks_axi_fork_is_detected
  test_wrapper_writes_through_to_home
  test_wrapper_overrides_ambient_file
  test_wrapper_refusals
  test_wrapper_refuses_add_start
  test_wrapper_owner_at_filing
  test_wrapper_single_home
  test_wrapper_hold_quote_guard
  test_wrapper_row_shape
  test_wrapper_close_writes_handoff_reply
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi

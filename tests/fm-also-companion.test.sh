#!/usr/bin/env bash
# Dependent-repository companion worktrees (fork patch, docs/fork-decisions.md
# 2026-10-14): bin/fm-spawn.sh --also grants a ship one leased, claimed, fresh
# companion slot per dependent repository and lists it in the launch brief;
# the brief's "Dependent repositories:" line and the spawn's flags must agree;
# bin/fm-pr-check.sh --also records a companion PR without touching the task's
# own PR or merge poll. bin/fm-teardown.sh's half lives in
# tests/fm-teardown.test.sh beside the rest of its landed-work cases.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-also-companion)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

git_commit() {  # <dir> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

# One repository with a bare origin and one managed Treehouse pool slot of it.
# Echoes "<project>|<slot>|<pool>".
make_repo_with_slot() {  # <case-dir> <name> <project-dir>
  local case_dir=$1 name=$2 project=$3 origin pool slot
  origin="$case_dir/$name-origin.git"
  pool="$case_dir/$name-pool"
  git init --quiet -b main "$project"
  printf '%s\n' "$name" > "$project/README.md"
  git -C "$project" add README.md
  git_commit "$project" initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" remote set-head origin main >/dev/null 2>&1 || true
  mkdir -p "$pool/1"
  git -C "$project" worktree add --quiet --detach "$pool/1/$name" HEAD
  slot=$(cd "$pool/1/$name" && pwd -P)
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
  printf '%s|%s|%s\n' "$(cd "$project" && pwd -P)" "$slot" "$pool"
}

# A home with the task's own project and a "jobs" clone under projects/, each
# with one pool slot, and a direct-PR ship brief scaffolded with <brief-args>.
make_case() {  # <name> <task-id> [brief-args...]
  local name=$1 id=$2 case_dir home rec
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  rec=$(make_repo_with_slot "$case_dir" sample "$case_dir/sample")
  IFS='|' read -r PROJECT_DIR POOL_DIR _ <<EOF
$rec
EOF
  rec=$(make_repo_with_slot "$case_dir" jobs "$home/projects/jobs")
  IFS='|' read -r JOBS_DIR JOBS_SLOT JOBS_POOL <<EOF
$rec
EOF
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample --mode direct-PR "$@" >/dev/null \
    || fail "$name: could not scaffold the brief"
  sed -i.bak -e 's/{TASK}/Change sample and jobs together./' \
    -e 's/{FIRSTMATE_SPEC}/Exercise the companion worktree spawn./' "$home/data/$id/brief.md"
  rm -f "$home/data/$id/brief.md.bak"
  FAKEBIN_DIR=$(make_spawn_fakebin "$case_dir/fake" gh gh-axi)
  fm_fake_treehouse_pool "$FAKEBIN_DIR"
  CASE_DIR=$case_dir
  HOME_DIR=$home
}

run_spawn() {  # <task-id> [args...]
  local id=$1
  shift
  FM_FAKE_TREEHOUSE_GET_POOLS="$JOBS_POOL" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

lease_holder() {  # <pool>
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).worktrees[0];
    process.stdout.write(w.leased ? w.lease_holder : "")' "$1/treehouse-state.json"
}

test_spawn_grants_a_companion_worktree() {
  local id='also-spawn-c1' out status advanced
  make_case spawn "$id" --also jobs
  # Advance jobs' origin after the slot was made, so the companion must be refreshed.
  git clone --quiet "file://$CASE_DIR/jobs-origin.git" "$CASE_DIR/jobs-publisher"
  printf 'advanced\n' > "$CASE_DIR/jobs-publisher/advanced.txt"
  git -C "$CASE_DIR/jobs-publisher" add advanced.txt
  git_commit "$CASE_DIR/jobs-publisher" advance
  git -C "$CASE_DIR/jobs-publisher" push --quiet origin main
  advanced=$(git -C "$CASE_DIR/jobs-publisher" rev-parse HEAD)

  out=$(run_spawn "$id" --mode direct-PR --yolo off --also jobs)
  status=$?
  expect_code 0 "$status" "a ship with --also jobs should launch"$'\n'"$out"
  assert_grep "also=jobs" "$HOME_DIR/state/$id.meta" "the task record does not list its companion repository"
  assert_grep "also_worktree_jobs=$JOBS_SLOT" "$HOME_DIR/state/$id.meta" \
    "the task record does not name the companion worktree"
  assert_grep "also_project_jobs=$JOBS_DIR" "$HOME_DIR/state/$id.meta" \
    "the task record does not name the companion project"
  assert_grep "- jobs: $JOBS_SLOT" "$HOME_DIR/data/$id/launch-brief.md" \
    "the launch brief does not list the companion worktree"
  [ "$(lease_holder "$JOBS_POOL")" = "$id" ] || fail "the companion slot is not leased to the task"
  grep -Fxq -- "task=$id" "$JOBS_POOL/1/.fm-slot-owner" || fail "the companion slot is not claimed for the task"
  [ "$(git -C "$JOBS_SLOT" rev-parse HEAD)" = "$advanced" ] \
    || fail "the companion worktree was not refreshed to origin's default branch"
  pass "spawn --also leases, claims, refreshes, records, and lists one companion worktree"
}

test_spawn_refuses_a_brief_and_flag_mismatch() {
  local id='also-mismatch-c1' out status
  make_case mismatch "$id" --also jobs
  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief naming jobs launched without --also"
  assert_contains "$out" "dependent repositories mismatch" "the mismatch refusal did not say why"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published a task record"
  [ -z "$(lease_holder "$JOBS_POOL")" ] || fail "a refused spawn leased a companion slot"

  id='also-unscaffolded-c1'
  make_case unscaffolded "$id"
  out=$(run_spawn "$id" --mode direct-PR --yolo off --also jobs)
  status=$?
  [ "$status" -ne 0 ] || fail "--also launched against a brief that names no dependent repository"
  assert_contains "$out" "dependent repositories mismatch" "the unscaffolded refusal did not say why"
  pass "a spawn refuses when its --also flags and the brief's Dependent repositories line disagree"
}

test_spawn_refuses_an_unusable_companion() {
  local id out status
  id='also-missing-c1'
  make_case missing "$id" --also ghost
  out=$(run_spawn "$id" --mode direct-PR --yolo off --also ghost)
  status=$?
  [ "$status" -ne 0 ] || fail "--also launched with no project clone for the companion"
  assert_contains "$out" "names no project clone" "the missing-project refusal did not say why"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn published a task record"

  id='also-scout-c1'
  make_case scout "$id"
  out=$(run_spawn "$id" --scout --also jobs)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout launched with --also"
  assert_contains "$out" "--also applies only to ship spawns" "the scout refusal did not say why"
  pass "a spawn refuses a companion with no clone, and --also on a scout"
}

test_spawn_refuses_an_external_or_unresolvable_companion_forge() {
  local id out status binding
  # A companion bound to an external review forge is refused, and a companion
  # binding the registry itself refuses fails closed instead of reading as none.
  for binding in forge=external forge=externl; do
    id="also-forge-${binding#forge=}-c1"
    make_case "forge-${binding#forge=}" "$id" --also jobs
    printf -- '- jobs [direct-PR %s] - companion (added 2026-10-19)\n' "$binding" > "$HOME_DIR/data/projects.md"
    out=$(run_spawn "$id" --mode direct-PR --yolo off --also jobs)
    status=$?
    [ "$status" -ne 0 ] || fail "--also launched with a companion registered $binding"
    case "$binding" in
      forge=external) assert_contains "$out" "--also jobs is refused for $id: it is registered forge=external" \
        "the external companion refusal did not say why"$'\n'"$out" ;;
      *) assert_contains "$out" "the registry entry for companion jobs does not resolve to a forge" \
        "the unresolvable companion refusal did not say why"$'\n'"$out" ;;
    esac
    assert_absent "$HOME_DIR/state/$id.meta" "a spawn refused for $binding published a task record"
    [ -z "$(lease_holder "$JOBS_POOL")" ] || fail "a spawn refused for $binding leased a companion slot"
  done
  pass "a spawn refuses a companion bound to an external forge or to a forge the registry refuses"
}

test_pr_check_records_a_companion_pr_without_arming() {
  local id='also-prcheck-c1' out status main_url='https://github.com/o/sample/pull/9'
  local url='https://github.com/o/jobs/pull/7'
  make_case prcheck "$id" --also jobs
  out=$(run_spawn "$id" --mode direct-PR --yolo off --also jobs)
  expect_code 0 "$?" "the companion spawn failed: $out"
  printf 'pr=%s\n' "$main_url" >> "$HOME_DIR/state/$id.meta"
  # The companion branch is pushed, so its named head is reachable off the copy.
  git -C "$JOBS_SLOT" checkout --quiet -b "fm/$id"
  printf 'jobs change\n' > "$JOBS_SLOT/change.txt"
  git -C "$JOBS_SLOT" add change.txt
  git_commit "$JOBS_SLOT" "companion change"
  git -C "$JOBS_SLOT" push --quiet origin "fm/$id"

  out=$(PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "$url" --also jobs 2>&1)
  status=$?
  expect_code 0 "$status" "pr-check --also failed: $out"
  assert_grep "also_pr_jobs=$url" "$HOME_DIR/state/$id.meta" "the companion PR was not recorded"
  assert_grep "pr=$main_url" "$HOME_DIR/state/$id.meta" "the task's own PR was replaced"
  assert_absent "$HOME_DIR/state/$id.check.sh" "a companion PR armed a merge poll"

  out=$(PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "https://github.com/o/fleet/pull/3" --also fleet 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "pr-check recorded a companion PR for a repository the task does not list"
  assert_contains "$out" "has no companion repository fleet" "the unknown-companion refusal did not say why"
  pass "pr-check --also records a companion PR and leaves the task's own PR and poll alone"
}

test_pr_check_companion_after_the_main_pr_keeps_its_poll_valid() {
  local id='also-prcheck-c2' out status wt main_url='https://github.com/o/sample/pull/9'
  local url='https://github.com/o/jobs/pull/7'
  make_case prcheck-order "$id" --also jobs
  out=$(run_spawn "$id" --mode direct-PR --yolo off --also jobs)
  expect_code 0 "$?" "the companion spawn failed: $out"
  # Both branches are pushed, so each named head is reachable off its copy.
  wt=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  for dir in "$wt" "$JOBS_SLOT"; do
    git -C "$dir" checkout --quiet -b "fm/$id"
    printf 'change\n' > "$dir/change.txt"
    git -C "$dir" add change.txt
    git_commit "$dir" change
    git -C "$dir" push --quiet origin "fm/$id"
  done

  out=$(PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "$main_url" 2>&1)
  expect_code 0 "$?" "pr-check of the main PR failed: $out"
  out=$(PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "$url" --also jobs 2>&1)
  status=$?
  expect_code 0 "$status" "pr-check --also failed: $out"
  assert_grep "also_pr_jobs=$url" "$HOME_DIR/state/$id.meta" "the companion PR was not recorded"
  # The watcher authenticates the main PR's poll through this gate and rejects
  # the task's check when the record has any other key after pr=.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_artifacts_valid "$HOME_DIR/state" "$id" "$ROOT/bin/fm-pr-poll.sh"
  ) || fail "a companion registered after the main PR invalidated its merge poll:"$'\n'"$(cat "$HOME_DIR/state/$id.meta")"
  pass "pr-check --also after the main PR keeps the main PR's merge poll valid"
}

test_spawn_grants_a_companion_worktree
test_spawn_refuses_a_brief_and_flag_mismatch
test_spawn_refuses_an_unusable_companion
test_spawn_refuses_an_external_or_unresolvable_companion_forge
test_pr_check_records_a_companion_pr_without_arming
test_pr_check_companion_after_the_main_pr_keeps_its_poll_valid

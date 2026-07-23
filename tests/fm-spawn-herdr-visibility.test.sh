#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's Herdr display-only title plumbing.
#
# These tests drive fm-spawn through real metadata publication with a fake Herdr
# CLI and a real isolated git worktree.
# The fake records pane labels and display metadata without starting a harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-visibility)

make_herdr_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}'
    ;;
  "workspace list")
    if [ "${FM_FAKE_FLEET:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"captain","active_tab_id":"captain:t1","label":"captain","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}'
    fi
    ;;
  "workspace create")
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}'
    ;;
  "tab list")
    case "$*" in
      *"--workspace captain"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"captain:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "pane get")
    pane=${3:-w1:p2}
    if [ "$pane" = w9:p1 ]; then
      printf '{"result":{"pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9","foreground_cwd":"%s"}}}\n' "${FM_FAKE_PANE_PATH:?}"
    else
      printf '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","foreground_cwd":"%s"}}}\n' "${FM_FAKE_PANE_PATH:?}"
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  log="$case_dir/herdr.log"
  fakebin=$(make_herdr_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$log"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$log"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR HERDR_LOG <<EOF
$1
EOF
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_FAKE_FLEET="${FM_FAKE_FLEET:-0}" \
    HERDR_SESSION=fmtest PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_explicit_title_uses_model_and_records_only_explicit_title() {
  local id rec out log meta
  id=visibility-model-v1
  rec=$(make_case title-model "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --backend herdr --model gpt-5.6-sol --title parser)
  expect_code 0 "$?" "Herdr spawn with explicit title and model should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" $'pane\x1frename\x1fw1:p2\x1fparser · gpt-5.6-sol' \
    "Herdr pane label did not compose the explicit title with the model"
  assert_contains "$log" $'pane\x1freport-metadata\x1fw1:p2\x1f--source\x1ffirstmate\x1f--title\x1fparser · gpt-5.6-sol\x1f--display-agent\x1fgpt-5.6-sol' \
    "Herdr display metadata did not report the composed title and effective model"
  assert_contains "$log" $'\x1f--label\x1ffm-'"$id"$'\x1f--no-focus' \
    "display title incorrectly replaced the task-id tab label"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "title=parser" "$meta" "explicit --title was not recorded in metadata"
  assert_grep "model=gpt-5.6-sol" "$meta" "model was not recorded in metadata"
  pass "Herdr display title composes explicit title with model without changing task authority"
}

test_default_title_uses_task_id_and_harness_without_meta_key() {
  local id rec out log meta
  id=visibility-harness-v2
  rec=$(make_case title-harness "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --backend herdr)
  expect_code 0 "$?" "Herdr spawn with default title should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" $'pane\x1frename\x1fw1:p2\x1f'"$id"$' · claude' \
    "Herdr pane label did not fall back to task id and harness"
  assert_contains "$log" $'--display-agent\x1fclaude' \
    "Herdr display metadata did not fall back to the harness"
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "title=" "$meta" "default task-id title must not add a title metadata key"
  pass "Herdr display title defaults to task id and harness without adding metadata"
}

test_fleet_refuses_non_herdr_backend() {
  local id rec out status
  id=visibility-fleet-refuse-v3
  rec=$(make_case fleet-refuse "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --backend tmux --fleet batch)
  status=$?
  expect_code 1 "$status" "--fleet on tmux should fail before endpoint creation"
  assert_contains "$out" "--fleet requires backend=herdr; resolved backend is 'tmux'" \
    "non-Herdr fleet refusal did not explain the backend requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "non-Herdr fleet refusal must not publish task metadata"
  pass "--fleet refuses non-Herdr backends instead of silently ignoring the grouping request"
}

test_fleet_refuses_secondmate_spawn() {
  local id rec out status
  id=visibility-fleet-secondmate-v1
  rec=$(make_case fleet-secondmate "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --backend herdr --fleet batch --secondmate)
  status=$?
  expect_code 1 "$status" "--fleet with --secondmate should fail before any mutation"
  assert_contains "$out" "--fleet cannot be combined with --secondmate; fleet grids are for crewmate/scout batches in one home, never cross-home secondmates" \
    "secondmate fleet refusal did not state the one-home crewmate/scout scope"
  assert_absent "$HOME_DIR/state/$id.meta" "secondmate fleet refusal must not publish task metadata"
  assert_absent "$HOME_DIR/state/.herdr-fleet-batch" "secondmate fleet refusal must not create a fleet record"
  [ ! -s "$HERDR_LOG" ] || fail "secondmate fleet refusal must not touch the Herdr backend"
  pass "--fleet refuses --secondmate spawns before any mutation instead of forming a cross-home grid"
}

test_ambiguous_fleet_record_falls_back_flat_without_reuse() {
  local id rec out log
  id=visibility-fleet-ambiguous-v4
  rec=$(make_case fleet-ambiguous "$id")
  read_case "$rec"
  printf '%s\n' \
    'version=1' \
    'fleet=batch' \
    'fleet_id=AbCdEfGhIjKlMnOpQrStUv' \
    'state=pending' > "$HOME_DIR/state/.herdr-fleet-batch"

  out=$(run_spawn "$id" "$PROJ_DIR" --backend herdr --fleet batch)
  expect_code 0 "$?" "ambiguous fleet record should fall back to an ordinary flat spawn"
  assert_contains "$out" "record is not an exact active record" \
    "ambiguous fleet record did not explain the flat fallback"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" $'\x1ftab\x1fcreate\x1f--workspace\x1fw1' \
    "ambiguous fleet record did not use the ordinary flat tab path"
  assert_not_contains "$log" $'\x1fpane\x1fsplit' \
    "ambiguous fleet record was incorrectly reused for a pane split"
  assert_grep "fleet=batch" "$HOME_DIR/state/$id.meta" \
    "flat fallback did not retain the explicit fleet request in task metadata"
  pass "ambiguous fleet records are left untouched while the spawn succeeds in the ordinary flat layout"
}

test_fleet_takes_precedence_over_presentation_spaces() {
  local id rec out log record meta
  id=visibility-fleet-precedence-v4
  rec=$(make_case fleet-precedence "$id")
  read_case "$rec"
  : > "$HOME_DIR/config/herdr-presentation-spaces"

  out=$(FM_FAKE_FLEET=1 run_spawn "$id" "$PROJ_DIR" --backend herdr --fleet batch --title parser --model gpt-5.6-sol)
  expect_code 0 "$?" "Herdr fleet spawn with presentation config should succeed"
  assert_contains "$out" "--fleet takes precedence over config/herdr-presentation-spaces" \
    "fleet spawn did not warn that the single-task presentation path was skipped"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" $'workspace\x1fcreate\x1f--cwd\x1f' \
    "fleet spawn did not create a dedicated workspace"
  assert_contains "$log" "/fleet-batch · f:" \
    "fleet spawn did not use a token-bearing fleet workspace label"
  assert_not_contains "$log" " · p:" \
    "fleet spawn incorrectly created a single-task presentation workspace"
  assert_not_contains "$log" $'\x1ftab\x1fcreate' \
    "first fleet member should use the exact root pane returned by workspace create"
  assert_contains "$log" $'pane\x1frename\x1fw9:p1\x1fparser · gpt-5.6-sol' \
    "fleet root pane did not receive the informative display title"
  record="$HOME_DIR/state/.herdr-fleet-batch"
  assert_grep "state=active" "$record" "fleet create did not activate its durable ownership record"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "fleet=batch" "$meta" "fleet spawn did not record fleet= in task metadata"
  assert_grep "herdr_workspace_id=w9" "$meta" "fleet spawn did not record the exact workspace id"
  assert_grep "herdr_pane_id=w9:p1" "$meta" "fleet spawn did not record the exact root pane id"
  pass "--fleet skips presentation spaces, creates one recorded workspace, and keeps title metadata display-only"
}

test_explicit_title_uses_model_and_records_only_explicit_title
test_default_title_uses_task_id_and_harness_without_meta_key
test_fleet_refuses_non_herdr_backend
test_fleet_refuses_secondmate_spawn
test_ambiguous_fleet_record_falls_back_flat_without_reuse
test_fleet_takes_precedence_over_presentation_spaces

echo "# all fm-spawn-herdr-visibility tests passed"

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
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true}}'
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

test_explicit_title_uses_model_and_records_only_explicit_title
test_default_title_uses_task_id_and_harness_without_meta_key

echo "# all fm-spawn-herdr-visibility tests passed"

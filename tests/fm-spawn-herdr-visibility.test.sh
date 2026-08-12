#!/usr/bin/env bash
# Behavior tests for what a Herdr spawn puts in front of a human, and what it
# deliberately keeps off the pane's screen:
#   - the display-only title plumbing (--title, the composed "<label> · <agent>"
#     pane title, and title= metadata only when the flag was explicit), and
#   - the native launch environment, delivered through `tab create --env` so the
#     local proxy credential is never typed at the pane's interactive shell.
#
# These drive the real fm-spawn.sh through metadata publication with a fake
# Herdr CLI and a real isolated git worktree. The fake records every argv it is
# called with, so assertions can prove both what reached `tab create` and what
# never reached `pane run`/`pane send-text`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-visibility)

# An obviously fake string on purpose: nothing in this suite may carry a real
# credential.
FAKE_TOKEN='sk-fake-not-a-real-token-000'

make_herdr_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
CWD_FILE="${FM_FAKE_HERDR_CWD:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true,"protocol":17}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[]}}'
    ;;
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${FM_FAKE_HERDR_PROJ:-}" "$(cat "$CWD_FILE")"
    ;;
  "pane run")
    # `treehouse get` is what moves the pane into its worktree.
    case "${4:-}" in
      *"treehouse get"*) printf '%s' "${FM_FAKE_HERDR_WT:?}" > "$CWD_FILE" ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id> -> echoes "home|proj|wt|fakebin|log|cwdfile"
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin log cwd_file
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  log="$case_dir/herdr.log"
  cwd_file="$case_dir/foreground_cwd"
  fakebin=$(make_herdr_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$log"
  printf '%s' "$proj" > "$cwd_file"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$log|$cwd_file"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR HERDR_LOG CWD_FILE <<EOF
$1
EOF
}

# write_endpoint_config <home>: one local-proxy entry whose token comes from an
# env var, never embedded.
write_endpoint_config() {
  cat > "$1/config/model-endpoints.json" <<'JSON'
{
  "endpoints": {
    "my-local-model": {
      "base_url": "http://127.0.0.1:8080",
      "auth_token_env": "FM_TEST_PROXY_TOKEN",
      "strict_mcp_config": true
    }
  }
}
JSON
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_PROXY_TOKEN="${FM_TEST_PROXY_TOKEN:-}" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_FAKE_HERDR_CWD="$CWD_FILE" \
    FM_FAKE_HERDR_PROJ="$PROJ_DIR" FM_FAKE_HERDR_WT="$WT_DIR" \
    HERDR_SESSION=fmtest GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    HERDR_ENV= HERDR_PANE_ID= HERDR_SOCKET_PATH= HERDR_TAB_ID= HERDR_WORKSPACE_ID= \
    "$SPAWN" "$@" 2>&1
}

# --- display titles ----------------------------------------------------------

test_explicit_title_uses_model_and_records_only_explicit_title() {
  local id rec out log meta
  id=visibility-model-v1
  rec=$(make_case title-model "$id"); read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --backend herdr --model sonnet --title parser)
  expect_code 0 "$?" "Herdr spawn with explicit title and model should succeed: $out"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" $'pane\x1frename\x1fw1:p2\x1fparser · sonnet' \
    "Herdr pane label did not compose the explicit title with the model"
  assert_contains "$log" $'pane\x1freport-metadata\x1fw1:p2\x1f--source\x1ffirstmate\x1f--title\x1fparser · sonnet\x1f--display-agent\x1fsonnet' \
    "Herdr display metadata did not report the composed title and effective model"
  assert_contains "$log" $'\x1f--label\x1ffm-'"$id"$'\x1f--no-focus' \
    "the display title incorrectly replaced the task-id tab label"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "title=parser" "$meta" "explicit --title was not recorded in metadata"
  assert_grep "model=sonnet" "$meta" "model was not recorded in metadata"
  pass "fm-spawn (herdr): a display title composes the explicit title with the model without changing task authority"
}

test_default_title_uses_task_id_and_harness_without_meta_key() {
  local id rec out log meta
  id=visibility-harness-v2
  rec=$(make_case title-harness "$id"); read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --backend herdr)
  expect_code 0 "$?" "Herdr spawn with a default title should succeed: $out"
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" $'pane\x1frename\x1fw1:p2\x1f'"$id"$' · claude' \
    "Herdr pane label did not fall back to the task id and harness"
  assert_contains "$log" $'--display-agent\x1fclaude' \
    "Herdr display metadata did not fall back to the harness"
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "title=" "$meta" "a default task-id title must not add a title metadata key"
  pass "fm-spawn (herdr): the display title defaults to the task id and harness without adding metadata"
}

test_title_rejects_empty_and_control_characters() {
  local id rec out status
  id=visibility-reject-v3
  rec=$(make_case title-reject "$id"); read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --backend herdr --title)
  status=$?
  [ "$status" -ne 0 ] || fail "--title with no value should refuse"
  assert_contains "$out" "--title requires a value" "an empty --title should say what is missing"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --backend herdr --title "$(printf 'bad\ttitle')")
  status=$?
  [ "$status" -ne 0 ] || fail "--title with a control character should refuse"
  assert_contains "$out" "control characters" "a control-character title should name the reason"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused title must not publish task metadata"
  pass "fm-spawn: --title refuses an empty value and control characters before anything is created"
}

# --- native launch environment ----------------------------------------------

test_spawn_herdr_sends_launch_env_natively_and_never_types_the_credential() {
  local id rec out logtext meta line status_file
  id=herdr-env-e1
  rec=$(make_case env-endpoint "$id"); read_case "$rec"
  write_endpoint_config "$HOME_DIR"

  out=$(FM_TEST_PROXY_TOKEN="$FAKE_TOKEN" run_spawn "$id" "$PROJ_DIR" --scout --backend herdr --model my-local-model)
  expect_code 0 "$?" "the herdr endpoint spawn should succeed: $out"

  logtext=$(cat "$HERDR_LOG")
  # 1. The credential and GOTMPDIR reach the pane process natively, at creation.
  assert_contains "$logtext" $'\x1f''tab'$'\x1f''create' "the spawn did not create a herdr tab"
  assert_contains "$logtext" $'\x1f''--env'$'\x1f''ANTHROPIC_AUTH_TOKEN='"$FAKE_TOKEN" \
    "the proxy credential must be placed on the launched process via tab create --env"
  assert_contains "$logtext" $'\x1f''--env'$'\x1f''GOTMPDIR=/tmp/fm-'"$id"'/gotmp' \
    "GOTMPDIR must be placed on the launched process via tab create --env"

  # 2. NOTHING is typed at the pane shell that carries either value. This is the
  #    acceptance bar: `pane run` / `pane send-text` / `pane send-keys` are the
  #    calls whose text lands on the pane's visible screen, which is what Herdr's
  #    optional pane history persists to disk. Assert the typed channel was
  #    genuinely exercised first, so this can never pass vacuously by the spawn
  #    simply never typing anything.
  assert_contains "$logtext" $'\x1f''pane'$'\x1f''run' "the spawn should still type the treehouse get command at the pane"
  assert_contains "$logtext" $'\x1f''pane'$'\x1f''send-text' "the spawn should still type the launch line at the pane"
  while IFS= read -r line; do
    case "$line" in
      *$'\x1f'pane$'\x1f'run*|*$'\x1f'pane$'\x1f'send-text*|*$'\x1f'pane$'\x1f'send-keys*)
        assert_not_contains "$line" "$FAKE_TOKEN" "the credential must never be typed at the pane shell"
        assert_not_contains "$line" "ANTHROPIC_AUTH_TOKEN" "no token export may be typed at the pane shell"
        assert_not_contains "$line" "export GOTMPDIR" "GOTMPDIR must not be typed at the pane shell on this backend"
        assert_not_contains "$line" "unset HISTFILE" \
          "with nothing secret typed, the history-file workaround must not be sent on this backend"
        ;;
    esac
  done <<EOF
$logtext
EOF

  # 3. The credential stays out of every durable record.
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "harness=claude" "$meta" "meta must still record harness=claude"
  assert_no_grep "$FAKE_TOKEN" "$meta" "the credential must never be written to meta"
  assert_no_grep "$FAKE_TOKEN" "$HOME_DIR/config/model-endpoints.json" "the credential must not be embedded in config"
  for status_file in "$HOME_DIR"/state/*.status; do
    [ -e "$status_file" ] || continue
    assert_no_grep "$FAKE_TOKEN" "$status_file" "the credential must never reach a status line"
  done
  pass "fm-spawn (herdr): launch env goes native via tab create --env and is never typed at the pane shell"
}

test_spawn_herdr_without_endpoint_sends_only_gotmpdir_natively() {
  local id rec out logtext
  id=herdr-env-e2
  rec=$(make_case env-plain "$id"); read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --backend herdr)
  expect_code 0 "$?" "an ordinary herdr spawn should succeed: $out"
  logtext=$(cat "$HERDR_LOG")
  assert_contains "$logtext" $'\x1f''--env'$'\x1f''GOTMPDIR=/tmp/fm-'"$id"'/gotmp' \
    "an ordinary spawn must still get GOTMPDIR natively"
  assert_not_contains "$logtext" "ANTHROPIC_AUTH_TOKEN" \
    "a spawn with no local endpoint must not carry any auth token env at all"
  assert_not_contains "$logtext" "export GOTMPDIR" \
    "GOTMPDIR must not also be typed at the pane shell (that would defeat the native path)"
  pass "fm-spawn (herdr): a spawn with no local endpoint still gets GOTMPDIR natively and no token env"
}

test_explicit_title_uses_model_and_records_only_explicit_title
test_default_title_uses_task_id_and_harness_without_meta_key
test_title_rejects_empty_and_control_characters
test_spawn_herdr_sends_launch_env_natively_and_never_types_the_credential
test_spawn_herdr_without_endpoint_sends_only_gotmpdir_natively

echo "# all fm-spawn-herdr-visibility tests passed"

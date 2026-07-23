#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's local model-endpoint injection (the local-proxy
# case: route a claude crewmate at a local Anthropic-shaped proxy via config/
# model-endpoints.json, WITHOUT a new harness). These drive fm-spawn through meta
# writing and launch construction with a fake tmux pane and a real isolated git
# worktree. The fake captures both the literal launch line (`send-keys -l`) and
# the pre-launch text-line sends, so assertions can prove:
#   - the endpoint env prefix + --strict-mcp-config land on the launch line,
#   - the auth token is exported SEPARATELY and never in the launch line or meta,
#   - harness=claude is preserved (all claude supervision facts still apply),
#   - a normal Anthropic model (or none) is byte-identical to a plain claude spawn,
#   - misconfig fails closed before any window/meta is created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-model-endpoint)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # A fake tmux that records the literal launch (send-keys -l) to FM_FAKE_LAUNCH_LOG
  # and every non-literal text-line send (send-keys -t TARGET TEXT Enter) to
  # FM_FAKE_SENT_LOG, so the token export line is observable but kept distinct from
  # the recorded launch string.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    is_literal=0
    for a in "$@"; do [ "$a" = "-l" ] && is_literal=1; done
    if [ "$is_literal" = 1 ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    else
      # send-keys -t TARGET TEXT [Enter]  ->  TEXT is the 4th arg.
      [ -n "${FM_FAKE_SENT_LOG:-}" ] && [ "$#" -ge 4 ] && printf '%s\n' "$4" >> "$FM_FAKE_SENT_LOG"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> -> echoes "case_dir|home|proj|wt|fakebin|launchlog|sentlog"
make_case() {
  local name=$1 case_dir home proj wt fakebin launchlog sentlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  sentlog="$case_dir/sent.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$sentlog"
}

read_case() {
  # shellcheck disable=SC2034  # CASE_DIR is part of the record; these cases don't use it.
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG SENT_LOG <<EOF
$1
EOF
}

# write_endpoint_config <home> : an example my-local-model -> local proxy entry,
# with the token sourced from an env var (never embedded).
write_endpoint_config() {
  local home=$1
  cat > "$home/config/model-endpoints.json" <<'JSON'
{
  "endpoints": {
    "my-local-model": {
      "base_url": "http://127.0.0.1:8080",
      "auth_token_env": "FM_TEST_PROXY_TOKEN",
      "strict_mcp_config": true,
      "env": {
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "my-local-model",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "my-local-model",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "my-local-model-small",
        "CLAUDE_CODE_SUBAGENT_MODEL": "my-local-model"
      }
    }
  }
}
JSON
}

write_endpoint_config_with_mcp() {
  local home=$1 mcp=$2
  cat > "$home/config/model-endpoints.json" <<JSON
{
  "endpoints": {
    "my-local-model": {
      "base_url": "http://127.0.0.1:8080",
      "auth_token_env": "FM_TEST_PROXY_TOKEN",
      "strict_mcp_config": true,
      "mcp_config": "$mcp"
    }
  }
}
JSON
}

# run_spawn <home> <wt> <fakebin> <launchlog> <sentlog> [--token <tok>] <spawn-args...>
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 sentlog=$5 token=
  shift 5
  if [ "${1:-}" = "--token" ]; then token=$2; shift 2; fi
  : > "$launchlog"; : > "$sentlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_SENT_LOG="$sentlog" \
    FM_TEST_PROXY_TOKEN="$token" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

seed_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
}

TOKEN='sk-proxy-tok-abc123XYZ'

test_endpoint_model_injects_prefix_and_strict_keeps_harness_claude() {
  local rec id out launch sent meta
  id=ep-inject-e1
  rec=$(make_case ep-inject); read_case "$rec"
  write_endpoint_config "$HOME_DIR"
  seed_brief "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model)
  expect_code 0 "$?" "endpoint spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude" "endpoint spawn must report harness=claude"

  launch=$(cat "$LAUNCH_LOG")
  # Endpoint env prefix on the launch line.
  assert_contains "$launch" "ANTHROPIC_BASE_URL='http://127.0.0.1:8080'" "launch missing base_url prefix"
  assert_contains "$launch" "ANTHROPIC_DEFAULT_OPUS_MODEL='my-local-model'" "launch missing opus mapping"
  assert_contains "$launch" "ANTHROPIC_DEFAULT_HAIKU_MODEL='my-local-model-small'" "launch missing haiku mapping"
  assert_contains "$launch" "CLAUDE_CODE_SUBAGENT_MODEL='my-local-model'" "launch missing subagent mapping"
  # It is still the same claude CLI with the same prompt-suggestion suppression.
  assert_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" \
    "launch must remain the claude CLI with prompt-suggestion suppression"
  assert_contains "$launch" "--model 'my-local-model' --strict-mcp-config" "launch missing --strict-mcp-config"
  assert_not_contains "$launch" "--mcp-config" "endpoint without mcp_config must keep the zero-MCP launch"

  # harness=claude preserved in meta; model recorded; token NOT recorded.
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "harness=claude" "$meta" "meta must record harness=claude"
  assert_grep "model=my-local-model" "$meta" "meta must record the model"
  assert_no_grep "$TOKEN" "$meta" "the auth token must never be written to meta"
  pass "endpoint model injects the env prefix + --strict-mcp-config and stays harness=claude"
}

test_endpoint_mcp_config_adds_deliberate_grant() {
  local rec id launch mcp
  id=ep-mcp-e9
  rec=$(make_case ep-mcp); read_case "$rec"
  mcp="$HOME_DIR/granted.mcp.json"
  printf '%s\n' '{"mcpServers":{"example":{"command":"true"}}}' > "$mcp"
  write_endpoint_config_with_mcp "$HOME_DIR" "$mcp"
  seed_brief "$HOME_DIR" "$id"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'my-local-model' --strict-mcp-config --mcp-config '$mcp'" \
    "configured mcp_config must be passed alongside strict mode"
  pass "an endpoint mcp_config adds one deliberate --mcp-config grant"
}

test_missing_endpoint_mcp_config_fails_closed_before_window() {
  local rec id out missing
  id=ep-mcp-missing-e10
  rec=$(make_case ep-mcp-missing); read_case "$rec"
  missing="$HOME_DIR/missing.mcp.json"
  write_endpoint_config_with_mcp "$HOME_DIR" "$missing"
  seed_brief "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model)
  expect_code 1 "$?" "a missing endpoint mcp_config must abort the spawn"
  assert_contains "$out" "refusing to launch claude against the real Anthropic API" \
    "abort message must retain the endpoint fail-closed explanation"
  assert_absent "$HOME_DIR/state/$id.meta" "mcp_config failure must happen before meta is written"
  [ ! -s "$LAUNCH_LOG" ] || fail "mcp_config failure must happen before a launch is sent"
  pass "a missing endpoint mcp_config fails closed before any launch or meta is created"
}

test_unreadable_endpoint_mcp_config_fails_closed() {
  local rec id mcp
  id=ep-mcp-unreadable-e11
  rec=$(make_case ep-mcp-unreadable); read_case "$rec"
  mcp="$HOME_DIR/unreadable.mcp.json"
  printf '%s\n' '{"mcpServers":{}}' > "$mcp"
  chmod 000 "$mcp"
  write_endpoint_config_with_mcp "$HOME_DIR" "$mcp"
  seed_brief "$HOME_DIR" "$id"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model >/dev/null 2>&1
  expect_code 1 "$?" "an unreadable endpoint mcp_config must abort the spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "unreadable mcp_config failure must happen before meta is written"
  chmod 600 "$mcp"
  pass "an unreadable endpoint mcp_config fails closed before launch"
}

test_token_exported_separately_never_in_launch_or_records() {
  local rec id launch sent meta f
  id=ep-secret-e2
  rec=$(make_case ep-secret); read_case "$rec"
  write_endpoint_config "$HOME_DIR"
  seed_brief "$HOME_DIR" "$id"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model >/dev/null

  launch=$(cat "$LAUNCH_LOG")
  sent=$(cat "$SENT_LOG")
  # The token is exported as its own pre-launch line...
  assert_contains "$sent" "export ANTHROPIC_AUTH_TOKEN='$TOKEN'" "token must be exported as a standalone pre-launch line"
  # ...and appears NOWHERE in the recorded launch string.
  assert_not_contains "$launch" "$TOKEN" "the auth token must never appear in the recorded launch string"
  assert_not_contains "$launch" "ANTHROPIC_AUTH_TOKEN" "the token env must not be composed into the launch string"

  # The token appears in no durable firstmate record: meta, status, or config.
  for f in "$HOME_DIR"/state/*.meta; do
    assert_no_grep "$TOKEN" "$f" "token leaked into $f"
  done
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "$TOKEN" "$meta" "token leaked into meta"
  # config only holds the env var NAME, never the value.
  assert_no_grep "$TOKEN" "$HOME_DIR/config/model-endpoints.json" "token must not be embedded in config"
  pass "the auth token is exported separately and absent from launch, meta, and config"
}

test_normal_model_unaffected_even_with_config_present() {
  local rec id launch sent expected
  id=ep-normal-e3
  rec=$(make_case ep-normal); read_case "$rec"
  write_endpoint_config "$HOME_DIR"   # config present, but 'sonnet' is not an endpoint
  seed_brief "$HOME_DIR" "$id"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model sonnet >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  sent=$(cat "$SENT_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model 'sonnet' \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "normal model launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_not_contains "$launch" "ANTHROPIC_BASE_URL" "normal model must not get an endpoint prefix"
  assert_not_contains "$launch" "strict-mcp-config" "normal model must not get --strict-mcp-config"
  assert_not_contains "$sent" "ANTHROPIC_AUTH_TOKEN" "normal model must not export a proxy token"
  pass "a normal Anthropic model is byte-identical to a plain claude spawn even with the config present"
}

test_no_model_unaffected_with_config_present() {
  local rec id launch expected
  id=ep-nomodel-e4
  rec=$(make_case ep-nomodel); read_case "$rec"
  write_endpoint_config "$HOME_DIR"
  seed_brief "$HOME_DIR" "$id"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-model launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "a claude spawn with no --model is unaffected by a present endpoint config"
}

test_turn_end_hook_still_installed_for_endpoint_launch() {
  local rec id hook
  id=ep-hook-e5
  rec=$(make_case ep-hook); read_case "$rec"
  write_endpoint_config "$HOME_DIR"
  seed_brief "$HOME_DIR" "$id"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model >/dev/null
  # The claude Stop hook (turn-end signal) is written into the worktree exactly as
  # for a normal claude spawn - the endpoint override does not disturb supervision.
  hook="$WT_DIR/.claude/settings.local.json"
  assert_present "$hook" "endpoint claude launch must still install the claude turn-end Stop hook"
  assert_grep "$id.turn-ended" "$hook" "turn-end hook must point at this task's turn-ended signal"
  pass "the claude turn-end hook is still installed for an endpoint-backed launch"
}

test_malformed_config_fails_closed_before_window() {
  local rec id out
  id=ep-bad-e6
  rec=$(make_case ep-bad); read_case "$rec"
  printf '{ not valid json ' > "$HOME_DIR/config/model-endpoints.json"
  seed_brief "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --model my-local-model)
  expect_code 1 "$?" "a malformed endpoint config must abort an endpoint-model spawn"
  assert_contains "$out" "refusing to launch claude against the real Anthropic API" \
    "abort message must explain the fail-closed reason"
  assert_absent "$HOME_DIR/state/$id.meta" "abort must happen before meta is written"
  pass "a malformed endpoint config fails closed before any window or meta is created"
}

test_unresolvable_token_fails_closed() {
  local rec id out
  id=ep-notok-e7
  rec=$(make_case ep-notok); read_case "$rec"
  write_endpoint_config "$HOME_DIR"
  seed_brief "$HOME_DIR" "$id"

  # Token env var deliberately empty -> unresolvable -> abort.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "" "$id" "$PROJ_DIR" --model my-local-model)
  expect_code 1 "$?" "an unresolvable token must abort the spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "token-failure abort must happen before meta is written"
  pass "an unresolvable proxy token fails closed before launch"
}

test_dispatch_profile_backstop_with_endpoint_model() {
  local rec id out launch
  id=ep-dispatch-e8
  rec=$(make_case ep-dispatch); read_case "$rec"
  write_endpoint_config "$HOME_DIR"
  # A dispatch profile is active, so fm-spawn requires an explicit harness. This
  # is the path firstmate takes: it resolves a profile that selects the endpoint
  # model and passes an explicit --harness claude --model <endpoint-model>.
  printf '%s\n' '{"rules":[{"when":"proxy work","use":{"harness":"claude","model":"my-local-model"}}]}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  seed_brief "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$SENT_LOG" \
    --token "$TOKEN" "$id" "$PROJ_DIR" --harness claude --model my-local-model)
  expect_code 0 "$?" "explicit harness must satisfy the dispatch backstop and apply the endpoint"
  assert_contains "$out" "spawned $id harness=claude" "backstop spawn must report harness=claude"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "ANTHROPIC_BASE_URL='http://127.0.0.1:8080'" "backstop path must still apply the endpoint prefix"
  assert_contains "$launch" "--model 'my-local-model' --strict-mcp-config" "backstop path must still add --strict-mcp-config"
  pass "the crew-dispatch backstop coexists with an endpoint model when firstmate passes an explicit harness"
}

test_endpoint_model_injects_prefix_and_strict_keeps_harness_claude
test_endpoint_mcp_config_adds_deliberate_grant
test_missing_endpoint_mcp_config_fails_closed_before_window
test_unreadable_endpoint_mcp_config_fails_closed
test_token_exported_separately_never_in_launch_or_records
test_dispatch_profile_backstop_with_endpoint_model
test_normal_model_unaffected_even_with_config_present
test_no_model_unaffected_with_config_present
test_turn_end_hook_still_installed_for_endpoint_launch
test_malformed_config_fails_closed_before_window
test_unresolvable_token_fails_closed

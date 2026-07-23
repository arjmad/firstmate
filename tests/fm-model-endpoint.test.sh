#!/usr/bin/env bash
# Behavior tests for bin/fm-model-endpoint.sh: the generic "this model resolves to
# this local endpoint" resolver. These pin config parsing, the exit-code contract
# fm-spawn relies on (0 match / 3 no-match / 2 fail-closed), token-source
# resolution priority, and the secret discipline that keeps the auth token out of
# the non-secret env output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EP="$ROOT/bin/fm-model-endpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-endpoint)

# write_config <name> <json> -> echoes the config dir holding model-endpoints.json
write_config() {
  local name=$1 json=$2 dir
  dir="$TMP_ROOT/$name/config"
  mkdir -p "$dir"
  printf '%s\n' "$json" > "$dir/model-endpoints.json"
  printf '%s\n' "$dir"
}

# run_resolve <config-dir> <args...> : run the resolver with a clean env override.
# OUT and CODE are set for the caller.
run_resolve() {
  local dir=$1
  shift
  OUT=$(FM_CONFIG_OVERRIDE="$dir" "$EP" "$@" 2>/dev/null)
  CODE=$?
}

SOL_JSON='{
  "endpoints": {
    "my-local-model": {
      "base_url": "http://127.0.0.1:8080",
      "auth_token_env": "FM_TEST_EP_TOKEN",
      "strict_mcp_config": true,
      "env": {
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "my-local-model",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "my-local-model-small",
        "CLAUDE_CODE_SUBAGENT_MODEL": "my-local-model"
      }
    }
  }
}'

test_match_emits_non_secret_records() {
  local dir
  dir=$(write_config match "$SOL_JSON")
  run_resolve "$dir" resolve my-local-model
  expect_code 0 "$CODE" "a configured model must resolve with exit 0"
  assert_contains "$OUT" "strict_mcp_config	1" "missing strict flag record"
  assert_contains "$OUT" "env	ANTHROPIC_BASE_URL	http://127.0.0.1:8080" "missing base_url env record"
  assert_contains "$OUT" "env	ANTHROPIC_DEFAULT_OPUS_MODEL	my-local-model" "missing opus mapping"
  assert_contains "$OUT" "env	ANTHROPIC_DEFAULT_HAIKU_MODEL	my-local-model-small" "missing haiku mapping"
  assert_contains "$OUT" "env	CLAUDE_CODE_SUBAGENT_MODEL	my-local-model" "missing subagent mapping"
  pass "a configured model resolves to its non-secret endpoint records"
}

test_env_output_never_contains_token() {
  local dir
  dir=$(write_config notoken "$SOL_JSON")
  # Token env var is set, but WITHOUT --with-token the resolver must never print it.
  OUT=$(FM_TEST_EP_TOKEN="sk-should-not-appear" FM_CONFIG_OVERRIDE="$dir" "$EP" resolve my-local-model 2>/dev/null)
  expect_code 0 "$?" "resolve without --with-token should still succeed on a valid entry"
  assert_not_contains "$OUT" "sk-should-not-appear" "the auth token must never appear in non-secret env output"
  assert_not_contains "$OUT" "token	" "no token record without --with-token"
  pass "the non-secret env output never carries the auth token"
}

test_with_token_env_source() {
  local dir
  dir=$(write_config withtok "$SOL_JSON")
  OUT=$(FM_TEST_EP_TOKEN="sk-env-tok-42" FM_CONFIG_OVERRIDE="$dir" "$EP" resolve --with-token my-local-model 2>/dev/null)
  expect_code 0 "$?" "resolve --with-token should succeed when the env token is set"
  assert_contains "$OUT" "token	sk-env-tok-42" "token record missing or wrong for env source"
  pass "auth_token_env resolves the token from the environment"
}

test_with_token_file_source() {
  local dir tokfile
  tokfile="$TMP_ROOT/filetok.secret"
  printf 'sk-file-tok-77\n' > "$tokfile"
  dir=$(write_config filetok "{
    \"endpoints\": { \"m-file\": {
      \"base_url\": \"http://127.0.0.1:9\",
      \"auth_token_file\": \"$tokfile\"
    } }
  }")
  run_resolve "$dir" resolve --with-token m-file
  expect_code 0 "$CODE" "file-backed token entry should resolve"
  assert_contains "$OUT" "token	sk-file-tok-77" "token record missing or wrong for file source"
  pass "auth_token_file reads the token from a gitignored file"
}

test_token_source_priority_env_over_file_over_literal() {
  local dir tokfile
  tokfile="$TMP_ROOT/prio.secret"
  printf 'sk-from-file\n' > "$tokfile"
  dir=$(write_config prio "{
    \"endpoints\": { \"m-prio\": {
      \"base_url\": \"http://x\",
      \"auth_token_env\": \"FM_TEST_EP_TOKEN\",
      \"auth_token_file\": \"$tokfile\",
      \"auth_token\": \"sk-literal\"
    } }
  }")
  # env set -> env wins
  OUT=$(FM_TEST_EP_TOKEN="sk-from-env" FM_CONFIG_OVERRIDE="$dir" "$EP" resolve --with-token m-prio 2>/dev/null)
  assert_contains "$OUT" "token	sk-from-env" "env token should win when present"
  # env empty -> falls through to file
  OUT=$(FM_TEST_EP_TOKEN="" FM_CONFIG_OVERRIDE="$dir" "$EP" resolve --with-token m-prio 2>/dev/null)
  assert_contains "$OUT" "token	sk-from-file" "empty env should fall through to the file source"
  pass "token source priority is env, then file, then literal"
}

test_no_match_exits_3() {
  local dir
  dir=$(write_config nomatch "$SOL_JSON")
  run_resolve "$dir" resolve some-ordinary-claude-model
  expect_code 3 "$CODE" "an unlisted model must exit 3 (launch normally)"
  assert_not_contains "$OUT" "ANTHROPIC_BASE_URL" "no records for an unlisted model"
  pass "an unlisted model exits 3 so the caller launches normally"
}

test_absent_config_exits_3() {
  local dir
  dir="$TMP_ROOT/absent/config"
  mkdir -p "$dir"  # no model-endpoints.json inside
  run_resolve "$dir" resolve my-local-model
  expect_code 3 "$CODE" "absent config must exit 3"
  pass "an absent config file exits 3 (feature off)"
}

test_empty_config_exits_3() {
  local dir
  dir="$TMP_ROOT/emptyfile/config"
  mkdir -p "$dir"
  printf '   \n\n' > "$dir/model-endpoints.json"
  run_resolve "$dir" resolve my-local-model
  expect_code 3 "$CODE" "a whitespace-only config must exit 3, not fail closed"
  pass "an empty/whitespace-only config exits 3 (treated as absent)"
}

test_malformed_json_exits_2() {
  local dir
  dir="$TMP_ROOT/malformed/config"
  mkdir -p "$dir"
  printf '{ this is not json ' > "$dir/model-endpoints.json"
  run_resolve "$dir" resolve my-local-model
  expect_code 2 "$CODE" "malformed JSON must fail closed with exit 2"
  pass "malformed JSON fails closed (exit 2)"
}

test_missing_base_url_exits_2() {
  local dir
  dir=$(write_config nobase '{ "endpoints": { "m": { "auth_token": "t" } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "an entry without base_url must fail closed"
  pass "a matched entry missing base_url fails closed (exit 2)"
}

test_no_token_source_exits_2() {
  local dir
  dir=$(write_config notok '{ "endpoints": { "m": { "base_url": "http://x" } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "an entry with no token source must fail closed"
  pass "a matched entry with no token source fails closed (exit 2)"
}

test_unresolvable_token_exits_2_and_prints_nothing() {
  local dir
  dir=$(write_config unresolv "$SOL_JSON")
  # FM_TEST_EP_TOKEN unset/empty and no other source -> token unresolvable.
  OUT=$(FM_TEST_EP_TOKEN="" FM_CONFIG_OVERRIDE="$dir" "$EP" resolve --with-token my-local-model 2>/dev/null)
  CODE=$?
  expect_code 2 "$CODE" "an unresolvable token must fail closed with exit 2"
  assert_not_contains "$OUT" "ANTHROPIC_BASE_URL" "a failed resolve must print no records at all"
  pass "an unresolvable token fails closed and emits nothing"
}

test_anthropic_auth_token_in_env_rejected() {
  local dir
  dir=$(write_config authinenv '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "t", "env": { "ANTHROPIC_AUTH_TOKEN": "leak" } } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "ANTHROPIC_AUTH_TOKEN inside env must be rejected"
  pass "ANTHROPIC_AUTH_TOKEN is refused inside the env map (forced through the token source)"
}

test_invalid_env_key_rejected() {
  local dir
  dir=$(write_config badkey '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "t", "env": { "1BAD": "v" } } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "an invalid env var name must fail closed"
  pass "an invalid env key name fails closed (exit 2)"
}

test_control_chars_in_token_sources_rejected() {
  local dir
  # A newline-bearing literal token used to be truncated-accepted, with its tail
  # lines leaking into the non-secret record stream as forged env records.
  dir=$(write_config ctrltok '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "sk-part1\nenv\tINJECTED_VAR\tevil" } } }')
  OUT=$(FM_CONFIG_OVERRIDE="$dir" "$EP" resolve --with-token m 2>/dev/null)
  CODE=$?
  expect_code 2 "$CODE" "a newline-bearing literal auth_token must fail closed"
  assert_not_contains "$OUT" "INJECTED_VAR" "the token tail must never leak into the record stream"
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "the same entry must fail closed without --with-token too"
  dir=$(write_config ctrltokenv '{ "endpoints": { "m": { "base_url": "http://x", "auth_token_env": "FM\tBAD" } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "a tab in auth_token_env must fail closed"
  dir=$(write_config ctrltokfile '{ "endpoints": { "m": { "base_url": "http://x", "auth_token_file": "/tmp/a\n/tmp/b" } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "a newline in auth_token_file must fail closed"
  pass "tab/newline control chars in any token-source string fail closed (exit 2)"
}

test_mcp_config_emits_readable_path() {
  local dir mcp
  mcp="$TMP_ROOT/granted.mcp.json"
  printf '%s\n' '{"mcpServers":{}}' > "$mcp"
  dir=$(write_config mcp "{ \"endpoints\": { \"m\": { \"base_url\": \"http://x\", \"auth_token\": \"t\", \"mcp_config\": \"$mcp\" } } }")
  run_resolve "$dir" resolve m
  expect_code 0 "$CODE" "a readable mcp_config should resolve"
  assert_contains "$OUT" $'mcp_config\t'"$mcp" "mcp_config record missing or wrong"
  pass "mcp_config emits the configured readable path"
}

test_relative_mcp_config_resolves_from_fm_home() {
  local home dir mcp
  home="$TMP_ROOT/mcp-relative-home"
  dir="$home/config"
  mcp="$home/mcp/granted.json"
  mkdir -p "$dir" "$(dirname "$mcp")"
  printf '%s\n' '{"mcpServers":{}}' > "$mcp"
  printf '%s\n' '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "t", "mcp_config": "mcp/granted.json" } } }' > "$dir/model-endpoints.json"
  OUT=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$dir" "$EP" resolve m 2>/dev/null)
  expect_code 0 "$?" "a relative mcp_config should resolve from FM_HOME"
  assert_contains "$OUT" $'mcp_config\t'"$mcp" "relative mcp_config did not resolve from FM_HOME"
  pass "a relative mcp_config resolves from the effective FM_HOME"
}

test_missing_mcp_config_exits_2_and_prints_nothing() {
  local dir missing
  missing="$TMP_ROOT/missing.mcp.json"
  dir=$(write_config mcpmissing "{ \"endpoints\": { \"m\": { \"base_url\": \"http://x\", \"auth_token\": \"t\", \"mcp_config\": \"$missing\" } } }")
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "a missing mcp_config must fail closed"
  assert_not_contains "$OUT" "ANTHROPIC_BASE_URL" "a failed mcp_config resolve must print no records"
  pass "a missing mcp_config fails closed before records are emitted"
}

test_invalid_mcp_config_value_exits_2() {
  local dir
  dir=$(write_config mcpinvalid '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "t", "mcp_config": 42 } } }')
  run_resolve "$dir" resolve m
  expect_code 2 "$CODE" "a non-string mcp_config must fail closed"
  pass "an invalid mcp_config value fails closed"
}

test_strict_defaults_true_when_absent() {
  local dir
  dir=$(write_config strictdefault '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "t" } } }')
  run_resolve "$dir" resolve m
  expect_code 0 "$CODE" "a valid minimal entry should resolve"
  assert_contains "$OUT" "strict_mcp_config	1" "strict_mcp_config must default to on"
  pass "strict_mcp_config defaults to on when the entry omits it"
}

test_strict_can_be_disabled() {
  local dir
  dir=$(write_config strictoff '{ "endpoints": { "m": { "base_url": "http://x", "auth_token": "t", "strict_mcp_config": false } } }')
  run_resolve "$dir" resolve m
  assert_contains "$OUT" "strict_mcp_config	0" "strict_mcp_config false must emit 0"
  pass "strict_mcp_config can be turned off"
}

test_usage_and_bad_subcommand() {
  OUT=$("$EP" --help 2>&1); expect_code 0 "$?" "--help should exit 0"
  assert_contains "$OUT" "model-endpoints.json" "help should describe the config file"
  "$EP" bogus >/dev/null 2>&1; expect_code 64 "$?" "an unknown subcommand should exit 64"
  "$EP" resolve >/dev/null 2>&1; expect_code 64 "$?" "resolve without a model should exit 64"
  pass "usage and bad-subcommand handling exit with clear codes"
}

test_match_emits_non_secret_records
test_env_output_never_contains_token
test_with_token_env_source
test_with_token_file_source
test_token_source_priority_env_over_file_over_literal
test_no_match_exits_3
test_absent_config_exits_3
test_empty_config_exits_3
test_malformed_json_exits_2
test_missing_base_url_exits_2
test_no_token_source_exits_2
test_unresolvable_token_exits_2_and_prints_nothing
test_anthropic_auth_token_in_env_rejected
test_invalid_env_key_rejected
test_control_chars_in_token_sources_rejected
test_mcp_config_emits_readable_path
test_relative_mcp_config_resolves_from_fm_home
test_missing_mcp_config_exits_2_and_prints_nothing
test_invalid_mcp_config_value_exits_2
test_strict_defaults_true_when_absent
test_strict_can_be_disabled
test_usage_and_bad_subcommand

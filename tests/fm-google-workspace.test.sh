#!/usr/bin/env bash
# Tests for fm-google-workspace.sh, the per-account Google Workspace MCP wiring.
#
# The property under test throughout is the account boundary. Nearly every tool the
# server exposes takes the target mailbox as an ordinary call argument, so a shared
# instance would leave the separation between the captain's accounts - and between
# those and another agent's - to a string a model emits. The chosen architecture moves
# that boundary into the filesystem: one instance per account, each pointed at its own
# credentials directory. These cases assert the boundary holds where it is decided:
# in the configured account table, in the generated runtime configuration, and in the
# deletion path, which must never widen from one account's own files.
#
# Every case runs against its own root, its own firstmate home holding a placeholder
# config/google-workspace, and a stubbed Claude Code CLI, so nothing here reads or
# writes real credentials, real Claude Code configuration, or Bitwarden.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GWS="$ROOT/bin/fm-google-workspace.sh"
TMP_ROOT=$(fm_test_tmproot fm-google-workspace)
FM_TEST_HOME="$TMP_ROOT/home-fm"
CONFIG_FILE="$FM_TEST_HOME/config/google-workspace"

# The placeholder account table: two accounts on domains the wizard case declares
# consumer ones and one Workspace-shaped account, so the admin note has something to
# fire on and something to leave out.
PERSONAL_ACCOUNT=alpha@example.com
WORKSPACE_ACCOUNT=ops@example-corp.com
THIRD_ACCOUNT=bravo@example.org

# An account that belongs to another agent is simply absent from the table. It appears
# here exactly once, as the thing every account-taking subcommand must refuse.
OTHER_AGENT_ACCOUNT=other-agent@example.net

# write_config [<body>] writes the home's config file; the default body is the three
# placeholder accounts plus placeholder Bitwarden coordinates.
write_config() {
  mkdir -p "$FM_TEST_HOME/config"
  if [ "$#" -ge 1 ]; then
    printf '%s\n' "$1" > "$CONFIG_FILE"
    return 0
  fi
  cat > "$CONFIG_FILE" <<EOF
# placeholder fixture
account alpha $PERSONAL_ACCOUNT
account ops   $WORKSPACE_ACCOUNT

account bravo $THIRD_ACCOUNT
bws_project_id 00000000-0000-4000-8000-000000000000
bws_secret_key google-oauth/desktop-client-fixture
EOF
}

# new_root <name> echoes a fresh, initialized workspace root.
new_root() {
  local root="$TMP_ROOT/$1"
  mkdir -p "$root"
  printf '%s\n' "$root"
}

# gws <root> <args...> runs the tool against an isolated root, the test's own firstmate
# home, a stubbed Claude Code CLI, and a HOME with no Bitwarden token, so no case can
# reach real state. FM_GWS_SERVER defaults empty so the host's own launcher never leaks in.
gws() {
  local root=$1; shift
  FM_GWS_SERVER="${FM_GWS_SERVER-}" FM_HOME="$FM_TEST_HOME" FM_GWS_ROOT="$root" FM_GWS_CLAUDE="$TMP_ROOT/stub/claude" HOME="$TMP_ROOT/home" "$GWS" "$@"
}

# stub_claude records every invocation so a case can assert what was registered.
stub_claude() {
  mkdir -p "$TMP_ROOT/stub" "$TMP_ROOT/home"
  cat > "$TMP_ROOT/stub/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_STUB_LOG"
[ "${CLAUDE_STUB_REMOVE_FAILS:-0}" = 1 ] && [ "${2:-}" = remove ] && exit 1
exit 0
SH
  chmod 0755 "$TMP_ROOT/stub/claude"
}

# store_credential <dir> <email> writes a credential file under the server's own
# naming rule: the URL-encoded verified email, which is how a directory records which
# account actually signed in.
store_credential() {
  local dir=$1 email=$2 name
  mkdir -p "$dir"
  name=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="@._-"))' "$email")
  printf '{"token": "redacted"}' > "$dir/$name.json"
}

desktop_client_json() {
  cat > "$1" <<'JSON'
{"installed": {"client_id": "fixture.apps.googleusercontent.com", "client_secret": "fixture-secret",
 "auth_uri": "https://accounts.google.com/o/oauth2/auth", "token_uri": "https://oauth2.googleapis.com/token"}}
JSON
}

test_only_the_configured_accounts_are_listed() {
  local root out
  root=$(new_root accounts)
  out=$(gws "$root" accounts)
  assert_contains "$out" "$PERSONAL_ACCOUNT" "the first configured account is listed"
  assert_contains "$out" "$WORKSPACE_ACCOUNT" "the Workspace-shaped account is listed"
  assert_contains "$out" "$THIRD_ACCOUNT" "the third configured account is listed"
  assert_not_contains "$out" "$OTHER_AGENT_ACCOUNT" "an account absent from the config must never be listed"
  expect_code 3 "$(gws "$root" accounts | wc -l | tr -d ' ')" "exactly the three configured accounts are listed"
  pass "only the configured accounts are listed"
}

test_an_unlisted_account_is_refused_by_every_subcommand() {
  local root out code verb
  root=$(new_root refuse)
  for verb in paths auth verify revoke; do
    out=$(gws "$root" "$verb" "$OTHER_AGENT_ACCOUNT" 2>&1) && code=0 || code=$?
    assert_contains "$out" "unknown account" "$verb refuses an account absent from the config"
    expect_code 1 "$code" "$verb exits non-zero for an account absent from the config"
  done
  pass "an unlisted account is refused by every account-taking subcommand"
}

# The config file is the enforcement point, so there must be no built-in table to fall
# back to: without an acceptable file, every subcommand refuses and names the file and
# the accepted format, and help is the only thing that still answers.
test_a_missing_or_malformed_config_refuses_every_subcommand() {
  local root out code verb
  root=$(new_root config)
  rm -f "$CONFIG_FILE"
  for verb in accounts init status claude-config hermes-config argv; do
    out=$(gws "$root" "$verb" 2>&1) && code=0 || code=$?
    expect_code 1 "$code" "$verb refuses without a config file"
    assert_contains "$out" "$CONFIG_FILE" "the $verb refusal names the config file"
    assert_contains "$out" "account <slug> <email>" "the $verb refusal states the accepted format"
  done
  assert_absent "$root/accounts" "a refused init created nothing"
  out=$(gws "$root" help 2>&1) || fail "help must still answer without a config file"
  assert_contains "$out" "Usage" "help answers without a config file"
  write_config "$(printf 'account alpha %s\nnot-a-setting here\n' "$PERSONAL_ACCOUNT")"
  out=$(gws "$root" accounts 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a malformed line refuses the command"
  assert_contains "$out" "line 2" "the refusal names the malformed line"
  write_config "$(printf 'account alpha %s\naccount alpha %s\n' "$PERSONAL_ACCOUNT" "$THIRD_ACCOUNT")"
  out=$(gws "$root" accounts 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a duplicate slug refuses the command"
  assert_contains "$out" "duplicate slug 'alpha'" "the refusal names the duplicate slug"
  write_config "$(printf 'account alpha not-an-address\n')"
  out=$(gws "$root" accounts 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an implausible email refuses the command"
  assert_contains "$out" "not a plausible email" "the refusal names the implausible email"
  write_config "$(printf 'account alpha %s\naccount alpha-2 %s\n' "$PERSONAL_ACCOUNT" "$PERSONAL_ACCOUNT")"
  out=$(gws "$root" accounts 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a duplicate email refuses the command"
  write_config "$(printf 'account alpha %s\n' "$PERSONAL_ACCOUNT")"
  out=$(gws "$root" client-secret push-bws 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "push-bws refuses without Bitwarden coordinates"
  assert_contains "$out" "bws_project_id" "the refusal names the missing Bitwarden setting"
  write_config
  pass "a missing or malformed config refuses every subcommand rather than falling back"
}

test_credentials_directories_are_private_to_the_user() {
  local root slug mode
  root=$(new_root init)
  gws "$root" init >/dev/null
  for slug in alpha ops bravo; do
    assert_present "$root/accounts/$slug" "$slug has a credentials directory"
    mode=$(python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "04o"))' "$root/accounts/$slug")
    [ "$mode" = 0700 ] || fail "$slug credentials directory is $mode, expected 0700"
  done
  gws "$root" init >/dev/null || fail "init is not idempotent"
  pass "credentials directories are created private to the user, idempotently"
}

test_the_invocation_requests_send_capable_scopes_per_service() {
  local root out
  root=$(new_root argv)
  out=$(gws "$root" argv)
  assert_contains "$out" "--single-user" "single-user mode binds the instance to one account"
  assert_contains "$out" "--permissions" "permissions is what narrows the OAuth token itself"
  assert_contains "$out" "gmail:full" "send is authorized for these accounts"
  assert_not_contains "$out" "--read-only" "read-only would contradict the authorized send"
  assert_not_contains "$out" "--tool-tier" "tool-tier shrinks the tool list without narrowing the token"
  # --permissions is mutually exclusive with --tools, so naming both would fail at launch.
  assert_not_contains "$out" "--tools" "tools cannot be combined with permissions"
  pass "the invocation requests send-capable scopes through permissions alone"
}

test_each_runtime_server_gets_its_own_credentials_directory() {
  local root config slug
  root=$(new_root perruntime)
  config=$(gws "$root" claude-config)
  for slug in alpha ops bravo; do
    assert_contains "$config" "\"gws-$slug\"" "Claude Code gets a separate server for $slug"
    assert_contains "$config" "$root/accounts/$slug" "$slug points at its own credentials directory"
  done
  python3 -c 'import json, sys; json.load(sys.stdin)' <<<"$config" || fail "claude-config is not valid JSON"
  # The boundary only holds if no two servers share a directory.
  expect_code 3 "$(printf '%s' "$config" | grep -c WORKSPACE_MCP_CREDENTIALS_DIR)" "three distinct credential directories"
  pass "each runtime server gets its own credentials directory"
}

test_the_two_runtimes_are_configured_from_one_invocation() {
  local root argv claude hermes
  root=$(new_root oneowner)
  argv=$(gws "$root" argv | tail -n +2 | tr '\n' ' ')
  claude=$(gws "$root" claude-config | python3 -c 'import json, sys; print(" ".join(json.load(sys.stdin)["mcpServers"]["gws-alpha"]["args"]) + " ")')
  hermes=$(gws "$root" hermes-config)
  [ "$argv" = "$claude" ] || fail "Claude Code args drifted from the tool's own invocation: '$claude' vs '$argv'"
  assert_contains "$hermes" "gmail:full" "the Hermes block carries the same permissions"
  assert_contains "$hermes" "trust: untrusted" "a mailbox server is untrusted input in Hermes"
  pass "both runtimes are configured from the one invocation the tool owns"
}

test_a_pinned_launcher_replaces_the_pypi_resolve() {
  local root pinned out claude hermes
  root=$(new_root pinned)
  pinned="$TMP_ROOT/pinned/bin/workspace-mcp"
  mkdir -p "$(dirname "$pinned")"
  printf '#!%s\n' "$(command -v python3)" > "$pinned"
  chmod 0755 "$pinned"
  out=$(FM_GWS_SERVER="$pinned" gws "$root" argv)
  [ "$(head -n 1 <<<"$out")" = "$pinned" ] || fail "argv does not start with the pinned launcher: $out"
  assert_not_contains "$out" "uvx" "a pinned launcher never resolves from PyPI"
  claude=$(FM_GWS_SERVER="$pinned" gws "$root" claude-config | python3 -c 'import json, sys; print(json.load(sys.stdin)["mcpServers"]["gws-alpha"]["command"])')
  [ "$claude" = "$pinned" ] || fail "Claude Code command is not the pinned launcher: $claude"
  hermes=$(FM_GWS_SERVER="$pinned" gws "$root" hermes-config)
  assert_contains "$hermes" "command: $pinned" "the Hermes block runs the pinned launcher"
  pass "a pinned launcher replaces the PyPI resolve in every consumer"
}

test_status_names_the_account_that_actually_signed_in() {
  local root out
  root=$(new_root status)
  gws "$root" init >/dev/null
  store_credential "$root/accounts/alpha" "$PERSONAL_ACCOUNT"
  store_credential "$root/accounts/ops" "$OTHER_AGENT_ACCOUNT"
  out=$(gws "$root" status)
  assert_contains "$out" "$PERSONAL_ACCOUNT        authorized" "a matching credential reads as authorized"
  assert_contains "$out" "not authorized yet" "an empty directory reads as not authorized"
  assert_contains "$out" "WRONG ACCOUNT" "a credential for another account is reported, not ignored"
  assert_contains "$out" "$OTHER_AGENT_ACCOUNT" "the wrong account is named so it can be removed"
  pass "status names the account that actually signed in"
}

test_reauthorizing_never_clears_another_accounts_credential() {
  local root out code
  root=$(new_root reauth)
  gws "$root" init >/dev/null
  desktop_client_json "$root/client_secret.json"
  store_credential "$root/accounts/bravo" "$OTHER_AGENT_ACCOUNT"
  out=$(gws "$root" auth bravo 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "auth refuses a directory holding another account"
  assert_contains "$out" "already holds credentials" "auth explains why it refused"
  assert_present "$root/accounts/bravo/$OTHER_AGENT_ACCOUNT.json" "auth removed nothing"
  pass "re-authorizing refuses rather than clearing another account's credential"
}

test_revoke_without_confirmation_deletes_nothing() {
  local root out code
  root=$(new_root revoke_unconfirmed)
  gws "$root" init >/dev/null
  store_credential "$root/accounts/alpha" "$PERSONAL_ACCOUNT"
  out=$(gws "$root" revoke alpha 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an unconfirmed revoke exits non-zero"
  assert_contains "$out" "Re-run with --yes" "an unconfirmed revoke says how to confirm"
  assert_present "$root/accounts/alpha/$PERSONAL_ACCOUNT.json" "an unconfirmed revoke deletes nothing"
  pass "revoke without confirmation deletes nothing"
}

test_revoke_deletes_only_that_accounts_own_credentials() {
  local root out
  root=$(new_root revoke_scope)
  gws "$root" init >/dev/null
  store_credential "$root/accounts/alpha" "$PERSONAL_ACCOUNT"
  store_credential "$root/accounts/ops" "$WORKSPACE_ACCOUNT"
  printf '{}' > "$root/accounts/alpha/oauth_states.json"
  printf 'unrelated' > "$root/client_secret.json"
  out=$(gws "$root" revoke alpha --yes)
  assert_absent "$root/accounts/alpha/$PERSONAL_ACCOUNT.json" "the account's credential is deleted"
  assert_present "$root/accounts/alpha/oauth_states.json" "the server's own bookkeeping file survives"
  assert_present "$root/accounts/ops/$WORKSPACE_ACCOUNT.json" "another account is untouched"
  assert_present "$root/client_secret.json" "nothing above the account directory is touched"
  assert_contains "$out" "myaccount.google.com/connections" "revoke says where the grant itself is ended"
  pass "revoke deletes only that account's own credentials"
}

test_registering_with_claude_code_keeps_the_accounts_apart() {
  local root log first second
  root=$(new_root claude)
  stub_claude
  log="$TMP_ROOT/claude-install.log"
  : > "$log"
  CLAUDE_STUB_LOG="$log" gws "$root" claude-install >/dev/null || fail "claude-install failed"
  first=$(cat "$log")
  assert_contains "$first" "mcp add -s user gws-alpha" "each account is registered as its own server"
  assert_contains "$first" "WORKSPACE_MCP_CREDENTIALS_DIR=$root/accounts/ops" "each server carries its own directory"
  assert_contains "$first" "GOOGLE_CLIENT_SECRET_PATH=$root/client_secret.json" "the shared OAuth client is passed by path, not by value"
  assert_contains "$first" "-- uvx workspace-mcp --single-user --permissions" "the registered command is the tool's own invocation"
  : > "$log"
  CLAUDE_STUB_LOG="$log" gws "$root" claude-install >/dev/null || fail "claude-install is not repeatable"
  second=$(grep -c "mcp remove" "$log")
  expect_code 3 "$second" "a repeat run replaces each server rather than adding a duplicate"
  pass "registering with Claude Code keeps the accounts apart"
}

test_only_a_desktop_oauth_client_is_installed_and_kept_private() {
  local root out code mode
  root=$(new_root clientsecret)
  gws "$root" init >/dev/null
  printf '{"web": {"client_id": "x", "client_secret": "y"}}' > "$TMP_ROOT/web-client.json"
  out=$(gws "$root" client-secret import "$TMP_ROOT/web-client.json" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a non-Desktop OAuth client is refused"
  assert_contains "$out" "Desktop" "the refusal names the required client type"
  assert_absent "$root/client_secret.json" "a refused client is not installed"
  desktop_client_json "$TMP_ROOT/desktop-client.json"
  gws "$root" client-secret import "$TMP_ROOT/desktop-client.json" >/dev/null || fail "a Desktop client was refused"
  mode=$(python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "04o"))' "$root/client_secret.json")
  [ "$mode" = 0600 ] || fail "the installed OAuth client is $mode, expected 0600"
  out=$(gws "$root" client-secret status)
  assert_contains "$out" "present" "status reports the client is installed"
  assert_not_contains "$out" "fixture-secret" "status must never print the secret itself"
  pass "only a Desktop OAuth client is installed, and it is kept private"
}

# The consent driver is bin/fm-google-workspace-auth.py. These two cases exercise it
# directly, without a server, because both refusals must land before it reaches the
# network: a run missing its OAuth client or its server invocation should say which
# input is wrong rather than fail somewhere inside a session it never should have
# opened.
test_the_consent_driver_refuses_without_a_server_invocation() {
    local out code
    out=$(python3 "$ROOT/bin/fm-google-workspace-auth.py" \
      --mode auth --email "$PERSONAL_ACCOUNT" --credentials-dir "$TMP_ROOT" 2>&1) && code=0 || code=$?
    expect_code 2 "$code" "the driver refuses with no invocation to run"
    assert_contains "$out" "required after --" "the refusal names the missing invocation"
    pass "the consent driver refuses without a server invocation"
}

test_the_consent_driver_refuses_without_an_oauth_client() {
    local out code
    out=$(GOOGLE_CLIENT_SECRET_PATH="$TMP_ROOT/absent.json" python3 "$ROOT/bin/fm-google-workspace-auth.py" \
      --mode auth --email "$PERSONAL_ACCOUNT" --credentials-dir "$TMP_ROOT" -- uvx workspace-mcp 2>&1) && code=0 || code=$?
    expect_code 1 "$code" "the driver refuses without a usable OAuth client"
    assert_contains "$out" "GOOGLE_CLIENT_SECRET_PATH" "the refusal names the missing input"
    pass "the consent driver refuses without an OAuth client"
}

test_auth_refuses_before_an_oauth_client_exists() {
  local root out code
  root=$(new_root noclient)
  gws "$root" init >/dev/null
  out=$(gws "$root" auth alpha 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "auth refuses without an OAuth client"
  assert_contains "$out" "no OAuth client secret" "the refusal names the missing requirement"
  pass "auth refuses before an OAuth client exists"
}

# The wizard drives the attended steps. This case runs it with no operator input at
# all, which is the shape a captain produces by stopping partway: it must still reach
# the end, name every step left undone, and never quietly report success it did not
# achieve. It also proves the wizard opens no browser and touches no real Claude Code
# configuration, since both are stubbed and asserted through their own logs. The
# admin note fires for the one Workspace-shaped account and names it, and the wizard
# refuses up front, with the tool's own message, when the config is absent.
test_the_wizard_completes_and_reports_what_is_left_undone() {
  local root out log opener code admin_note
  root=$(new_root wizard)
  stub_claude
  rm -f "$CONFIG_FILE"
  out=$(FM_HOME="$FM_TEST_HOME" FM_GWS_ROOT="$root" HOME="$TMP_ROOT/home" \
    bash "$ROOT/bin/fm-google-workspace-wizard.sh" </dev/null 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "the wizard refuses without a config file"
  assert_contains "$out" "$CONFIG_FILE" "the wizard's refusal names the config file"
  assert_not_contains "$out" "Stage 1" "the wizard refuses before its first stage"
  write_config
  # The wizard hands a URL to the first browser opener its host offers, so every
  # opener it can choose is stubbed and the console URL lands in the log on any host.
  mkdir -p "$TMP_ROOT/stub"
  for opener in wslview explorer.exe xdg-open open; do
    cat > "$TMP_ROOT/stub/$opener" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPEN_STUB_LOG"
SH
    chmod 0755 "$TMP_ROOT/stub/$opener"
  done
  log="$TMP_ROOT/wizard-open.log"
  : > "$log"
  : > "$TMP_ROOT/wizard-claude.log"
  out=$(PATH="$TMP_ROOT/stub:$PATH" OPEN_STUB_LOG="$log" CLAUDE_STUB_LOG="$TMP_ROOT/wizard-claude.log" \
    FM_GWS_SERVER="" FM_HOME="$FM_TEST_HOME" FM_GWS_ROOT="$root" FM_GWS_CLAUDE="$TMP_ROOT/stub/claude" HOME="$TMP_ROOT/home" \
    FM_GWS_CONSUMER_DOMAINS="example.com example.org" \
    bash "$ROOT/bin/fm-google-workspace-wizard.sh" </dev/null 2>&1) || fail "the wizard did not finish"
  assert_contains "$out" "Setup complete" "the wizard reaches its closing summary"
  assert_contains "$out" "still to do by hand" "an abandoned run reports the work left undone"
  assert_contains "$out" "was not authorized" "an account that did not sign in is reported as such"
  assert_contains "$out" "cade/config/config.yaml" "the wizard hands the Cade wiring over rather than editing it"
  assert_not_contains "$out" "$OTHER_AGENT_ACCOUNT" "the wizard never mentions an account absent from the config"
  assert_contains "$out" "Authorize $PERSONAL_ACCOUNT" "the wizard authorizes each configured account"
  assert_contains "$out" "Authorize $THIRD_ACCOUNT" "the wizard authorizes each configured account"
  admin_note=$(printf '%s\n' "$out" | sed -n '/can be blocked/,/Understood?/p')
  assert_contains "$admin_note" "$WORKSPACE_ACCOUNT" "the admin note names the Workspace-domain account"
  assert_not_contains "$admin_note" "$PERSONAL_ACCOUNT" "the admin note does not name a consumer-domain account"
  assert_not_contains "$admin_note" "$THIRD_ACCOUNT" "the admin note does not name a consumer-domain account"
  assert_grep "console.cloud.google.com" "$log" "the wizard opened the console for the captain"
  assert_grep "mcp add -s user gws-alpha" "$TMP_ROOT/wizard-claude.log" "the wizard registered the accounts it configured"
  pass "the wizard completes and reports what is left undone"
}

stub_claude
write_config
test_only_the_configured_accounts_are_listed
test_an_unlisted_account_is_refused_by_every_subcommand
test_a_missing_or_malformed_config_refuses_every_subcommand
test_credentials_directories_are_private_to_the_user
test_the_invocation_requests_send_capable_scopes_per_service
test_each_runtime_server_gets_its_own_credentials_directory
test_the_two_runtimes_are_configured_from_one_invocation
test_a_pinned_launcher_replaces_the_pypi_resolve
test_status_names_the_account_that_actually_signed_in
test_reauthorizing_never_clears_another_accounts_credential
test_revoke_without_confirmation_deletes_nothing
test_revoke_deletes_only_that_accounts_own_credentials
test_registering_with_claude_code_keeps_the_accounts_apart
test_only_a_desktop_oauth_client_is_installed_and_kept_private
test_auth_refuses_before_an_oauth_client_exists
test_the_consent_driver_refuses_without_a_server_invocation
test_the_consent_driver_refuses_without_an_oauth_client
test_the_wizard_completes_and_reports_what_is_left_undone

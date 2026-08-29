#!/usr/bin/env bash
# fm-google-workspace.sh - operate Arjun's per-account Google Workspace MCP instances.
#
# Architecture, captain-settled 2026-08-28: ONE google_workspace_mcp instance per
# Google account, --single-user, each with its own WORKSPACE_MCP_CREDENTIALS_DIR,
# over stdio, wired into both firstmate/Claude Code and Cade's Hermes.
# The per-instance credentials directory IS the account boundary: the target account
# is an ordinary call argument on nearly every tool, so a shared instance would leave
# the boundary to a string the model emits, while a process holding one account's
# directory cannot reach another mailbox whatever the model asks for.
# docs/google-workspace-access.md is the operator guide and this script's companion.
#
# Send is authorized for these three accounts (captain, 2026-08-29), so the permission
# set below is deliberately not --read-only.
#
# This script never prints a token, a refresh token, or a client secret, and it never
# deletes or overwrites a stored credential except through an explicitly confirmed
# revoke. Re-authorizing an account is additive: it refuses rather than clearing a
# credentials directory that holds an account other than the one being authorized.
#
# Usage:
#   fm-google-workspace.sh accounts                  print slug, email, and credentials dir
#   fm-google-workspace.sh argv                      print the exact workspace-mcp argv
#   fm-google-workspace.sh paths [<account>]         print the resolved paths
#   fm-google-workspace.sh init                      create the 0700 credentials dirs
#   fm-google-workspace.sh client-secret status      report presence and mode, never the value
#   fm-google-workspace.sh client-secret import <f>  install a downloaded client secret JSON at 0600
#   fm-google-workspace.sh client-secret push-bws    copy the installed client secret into BWS
#   fm-google-workspace.sh client-secret pull-bws    restore the client secret from BWS
#   fm-google-workspace.sh auth <account>            run one attended consent ceremony
#   fm-google-workspace.sh verify <account>          real read; prints the authenticated account
#   fm-google-workspace.sh status                    per-account readiness, values never shown
#   fm-google-workspace.sh claude-config             print the Claude Code MCP entries as JSON
#   fm-google-workspace.sh claude-install            register the servers in Claude Code user scope
#   fm-google-workspace.sh claude-uninstall          remove those same servers again
#   fm-google-workspace.sh hermes-config             print the Hermes mcp_servers YAML block
#   fm-google-workspace.sh revoke <account> [--yes]  delete that account's local credentials
#
# <account> is a slug (arjmad, ecomills, kempf) or its full email address.
# Any other value is refused: this account table is the enforcement point, and the
# Nova-only accounts are deliberately absent from it so no subcommand can reach them.
#
# Paths. FM_GWS_ROOT overrides the root, which otherwise defaults to
# ${XDG_STATE_HOME:-$HOME/.local/state}/google-workspace-mcp. The root is shared by
# both runtimes on purpose, so one consent per account serves firstmate and Hermes.
# FM_GWS_CLAUDE overrides the Claude Code CLI used by claude-install/claude-uninstall.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DRIVER="$SCRIPT_DIR/fm-google-workspace-auth.py"

# The account table. slug<TAB>email. Adding a row here grants agents access to that
# mailbox, so a row is a captain decision, not a maintenance edit.
ACCOUNTS=$(
  printf '%s\t%s\n' \
    arjmad    arjmad@gmail.com \
    ecomills  arjun@ecomills.com \
    kempf     williamkempf@gmail.com
)

# The exact per-service permission levels. --permissions is the only flag that moves
# the OAuth token boundary: --tool-tier and --disabled-tools shrink the tool list while
# still consenting to the full service scopes. It is mutually exclusive with --tools and
# --read-only, so this list also selects which services load at all.
PERMISSIONS="gmail:full drive:full calendar:full docs:full sheets:full contacts:full"

GWS_ROOT="${FM_GWS_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/google-workspace-mcp}"
ACCOUNTS_ROOT="$GWS_ROOT/accounts"
CLIENT_SECRET_FILE="$GWS_ROOT/client_secret.json"
BWS_PROJECT_ID=0e9c339e-c6d1-4069-8d05-b4a9001c7022
BWS_SECRET_KEY=google-oauth/desktop-client-arjun
CLAUDE_BIN="${FM_GWS_CLAUDE:-claude}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '20,46p' "$SCRIPT_DIR/fm-google-workspace.sh" | sed 's/^# \{0,1\}//'; }

all_slugs() { printf '%s\n' "$ACCOUNTS" | cut -f1 | paste -sd, -; }

# account_email and account_slug resolve a slug or email against the table above and
# fail for anything else, so no subcommand can be pointed at an unlisted mailbox.
account_email() {
  printf '%s\n' "$ACCOUNTS" | awk -F'\t' -v key="$1" '$1 == key || $2 == key { print $2; f = 1 } END { exit !f }'
}

account_slug() {
  printf '%s\n' "$ACCOUNTS" | awk -F'\t' -v key="$1" '$1 == key || $2 == key { print $1; f = 1 } END { exit !f }'
}

resolve_account() {
  [ "$#" -eq 1 ] && [ -n "${1:-}" ] || die "an account is required: $(all_slugs)"
  account_slug "$1" >/dev/null || die "unknown account '$1'; known accounts are $(all_slugs)"
}

creds_dir() { printf '%s/%s\n' "$ACCOUNTS_ROOT" "$(account_slug "$1")"; }

# server_argv prints the workspace-mcp invocation one token per line. Every consumer -
# the Claude Code entry, the Hermes block, and the consent ceremony - reads it from
# here, so the three can never drift from each other.
server_argv() {
  printf '%s\n' uvx workspace-mcp --single-user --permissions
  # shellcheck disable=SC2086 # deliberate word splitting: one permission token per line
  printf '%s\n' $PERMISSIONS
}

file_mode() {
  python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "04o"))' "$1"
}

ensure_dir_0700() {
  [ -n "${1:-}" ] || die "internal: refusing to create an unnamed directory"
  # umask, not mkdir -m: with -p the mode flag reaches only the deepest directory,
  # so any parent created on the way would land at the ambient default instead.
  [ -d "$1" ] || ( umask 077 && mkdir -p -- "$1" ) || die "cannot create $1"
  chmod 0700 "$1" || die "cannot secure $1"
}

# credential_files prints the exact path of every stored credential in a credentials
# directory, one per line, skipping the server's own oauth_states bookkeeping file.
# Callers that delete work from these exact paths rather than from a glob.
credential_files() {
  local dir="${1:-}" f base
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .json)
    [ "$base" = oauth_states ] && continue
    printf '%s\n' "$f"
  done
}

# credential_emails names the Google-verified accounts a credentials directory holds.
# The server stores each file under the email in the verified ID token, so a filename
# is the account that actually signed in, not the one that was requested.
credential_emails() {
  local f base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=$(basename "$f" .json)
    python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$base"
  done <<EOF
$(credential_files "${1:-}")
EOF
}

bws_token() {
  if [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
    printf '%s' "$BWS_ACCESS_TOKEN"
    return 0
  fi
  if [ -r "$HOME/.config/bws/access-token" ]; then
    cat "$HOME/.config/bws/access-token"
    return 0
  fi
  return 1
}

bws_secret_id() {
  BWS_ACCESS_TOKEN="$1" bws secret list "$BWS_PROJECT_ID" --output json 2>/dev/null \
    | python3 -c 'import json, sys
key = sys.argv[1]
print(next((s["id"] for s in json.load(sys.stdin) if s.get("key") == key), ""))' "$BWS_SECRET_KEY"
}

require_client_secret() {
  [ -f "$CLIENT_SECRET_FILE" ] \
    || die "no OAuth client secret at $CLIENT_SECRET_FILE; run bin/fm-google-workspace-wizard.sh or 'client-secret import <file>'"
}

cmd_accounts() {
  local slug email
  printf '%s\n' "$ACCOUNTS" | while IFS=$'\t' read -r slug email; do
    printf '%s\t%s\t%s\n' "$slug" "$email" "$ACCOUNTS_ROOT/$slug"
  done
}

cmd_paths() {
  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    resolve_account "$1"
    printf 'account:         %s\n' "$(account_email "$1")"
    printf 'server:          gws-%s\n' "$(account_slug "$1")"
    printf 'credentials dir: %s\n' "$(creds_dir "$1")"
    printf 'client secret:   %s\n' "$CLIENT_SECRET_FILE"
    return 0
  fi
  printf 'root:            %s\n' "$GWS_ROOT"
  printf 'accounts root:   %s\n' "$ACCOUNTS_ROOT"
  printf 'client secret:   %s\n' "$CLIENT_SECRET_FILE"
  printf 'permissions:     %s\n' "$PERMISSIONS"
}

cmd_init() {
  local slug email
  ensure_dir_0700 "$GWS_ROOT"
  ensure_dir_0700 "$ACCOUNTS_ROOT"
  printf '%s\n' "$ACCOUNTS" | while IFS=$'\t' read -r slug email; do
    ensure_dir_0700 "$ACCOUNTS_ROOT/$slug"
    printf 'ready: %s -> %s\n' "$email" "$ACCOUNTS_ROOT/$slug"
  done
}

cmd_client_secret() {
  local verb="${1:-status}" token id
  case "$verb" in
    status)
      if [ -f "$CLIENT_SECRET_FILE" ]; then
        printf 'client secret: present at %s (mode %s)\n' "$CLIENT_SECRET_FILE" "$(file_mode "$CLIENT_SECRET_FILE")"
      else
        printf 'client secret: ABSENT at %s\n' "$CLIENT_SECRET_FILE"
      fi
      if bws_token >/dev/null 2>&1; then
        printf 'bws token:     available\n'
      else
        printf 'bws token:     ABSENT (set BWS_ACCESS_TOKEN or write ~/.config/bws/access-token)\n'
      fi
      ;;
    import)
      [ "$#" -eq 2 ] || die "usage: client-secret import <downloaded-client-secret.json>"
      [ -f "$2" ] || die "no such file: $2"
      python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
if "installed" not in d:
    sys.exit("not a Desktop OAuth client (expected an \"installed\" key)")
for k in ("client_id", "client_secret"):
    if not d["installed"].get(k):
        sys.exit("client secret JSON is missing " + k)' "$2" || die "refusing to install that file"
      ensure_dir_0700 "$GWS_ROOT"
      ( umask 077 && cp -- "$2" "$CLIENT_SECRET_FILE" ) || die "cannot install the client secret"
      chmod 0600 "$CLIENT_SECRET_FILE" || die "cannot secure $CLIENT_SECRET_FILE"
      printf 'installed: %s (0600)\n' "$CLIENT_SECRET_FILE"
      ;;
    push-bws)
      require_client_secret
      token=$(bws_token) || die "no BWS access token; set BWS_ACCESS_TOKEN or write ~/.config/bws/access-token"
      id=$(bws_secret_id "$token") || die "cannot list the shared BWS project"
      if [ -n "$id" ]; then
        BWS_ACCESS_TOKEN="$token" bws secret edit "$id" --value "$(cat "$CLIENT_SECRET_FILE")" --output none \
          || die "cannot update $BWS_SECRET_KEY"
        printf 'updated: %s in the shared BWS project\n' "$BWS_SECRET_KEY"
      else
        BWS_ACCESS_TOKEN="$token" bws secret create "$BWS_SECRET_KEY" "$(cat "$CLIENT_SECRET_FILE")" \
          "$BWS_PROJECT_ID" --note "Desktop OAuth client for Arjun's Google Workspace MCP instances" --output none \
          || die "cannot create $BWS_SECRET_KEY"
        printf 'created: %s in the shared BWS project\n' "$BWS_SECRET_KEY"
      fi
      ;;
    pull-bws)
      token=$(bws_token) || die "no BWS access token; set BWS_ACCESS_TOKEN or write ~/.config/bws/access-token"
      id=$(bws_secret_id "$token") || die "cannot list the shared BWS project"
      [ -n "$id" ] || die "$BWS_SECRET_KEY is not in the shared BWS project yet"
      [ ! -f "$CLIENT_SECRET_FILE" ] \
        || die "$CLIENT_SECRET_FILE already exists; move it aside yourself if you mean to replace it"
      ensure_dir_0700 "$GWS_ROOT"
      BWS_ACCESS_TOKEN="$token" bws secret get "$id" --output json \
        | python3 -c 'import json, os, sys
value = json.load(sys.stdin)["value"]
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(value)' "$CLIENT_SECRET_FILE" || die "cannot restore the client secret"
      printf 'restored: %s (0600)\n' "$CLIENT_SECRET_FILE"
      ;;
    *) die "unknown client-secret verb '$verb'; expected status, import, push-bws, or pull-bws" ;;
  esac
}

run_driver() {
  local mode="$1" account="$2" email dir argv
  email=$(account_email "$account")
  dir=$(creds_dir "$account")
  require_client_secret
  ensure_dir_0700 "$GWS_ROOT"
  ensure_dir_0700 "$ACCOUNTS_ROOT"
  ensure_dir_0700 "$dir"
  command -v uv >/dev/null 2>&1 || die "uv is not installed; it provides the uvx that runs workspace-mcp"
  argv=$(server_argv)
  # shellcheck disable=SC2086 # deliberate word splitting: one argv token per line
  GOOGLE_CLIENT_SECRET_PATH="$CLIENT_SECRET_FILE" \
    uv run --no-project --with workspace-mcp python3 "$AUTH_DRIVER" \
      --mode "$mode" --email "$email" --credentials-dir "$dir" -- $argv
}

# cmd_auth refuses, rather than clearing, a directory that already holds a different
# account: nothing here removes a credential the operator did not ask to replace.
cmd_auth() {
  resolve_account "${1:-}"
  local email dir held
  email=$(account_email "$1")
  dir=$(creds_dir "$1")
  held=$(credential_emails "$dir" | grep -vxF "$email" | paste -sd, -)
  [ -z "$held" ] || die "$dir already holds credentials for $held; run 'revoke $1 --yes' first if you mean to replace them"
  run_driver auth "$1"
}

cmd_verify() { resolve_account "${1:-}"; run_driver verify "$1"; }

cmd_status() {
  local slug email dir held
  printf 'root: %s\n' "$GWS_ROOT"
  if [ -f "$CLIENT_SECRET_FILE" ]; then printf 'client secret: present\n'; else printf 'client secret: ABSENT\n'; fi
  printf '%s\n' "$ACCOUNTS" | while IFS=$'\t' read -r slug email; do
    dir="$ACCOUNTS_ROOT/$slug"
    held=$(credential_emails "$dir" | paste -sd, -)
    if [ -z "$held" ]; then
      printf '%-9s %-24s not authorized yet\n' "$slug" "$email"
    elif [ "$held" = "$email" ]; then
      printf '%-9s %-24s authorized\n' "$slug" "$email"
    else
      printf '%-9s %-24s WRONG ACCOUNT in %s: %s\n' "$slug" "$email" "$dir" "$held"
    fi
  done
}

cmd_claude_config() {
  local argv
  argv=$(server_argv | tail -n +2)
  printf '%s\n' "$ACCOUNTS" | python3 -c 'import json, sys
args = sys.argv[1].split()
accounts_root, client_secret = sys.argv[2], sys.argv[3]
servers = {}
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    slug = line.split("\t")[0]
    servers["gws-" + slug] = {
        "type": "stdio",
        "command": "uvx",
        "args": args,
        "env": {
            "WORKSPACE_MCP_CREDENTIALS_DIR": accounts_root + "/" + slug,
            "GOOGLE_CLIENT_SECRET_PATH": client_secret,
        },
    }
print(json.dumps({"mcpServers": servers}, indent=2))' "$argv" "$ACCOUNTS_ROOT" "$CLIENT_SECRET_FILE"
}

cmd_claude_install() {
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "$CLAUDE_BIN is not on PATH"
  local slug email argv
  argv=$(server_argv | tail -n +2)
  printf '%s\n' "$ACCOUNTS" | while IFS=$'\t' read -r slug email; do
    "$CLAUDE_BIN" mcp remove -s user "gws-$slug" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086 # deliberate word splitting: one argv token per line
    "$CLAUDE_BIN" mcp add -s user "gws-$slug" \
      -e "WORKSPACE_MCP_CREDENTIALS_DIR=$ACCOUNTS_ROOT/$slug" \
      -e "GOOGLE_CLIENT_SECRET_PATH=$CLIENT_SECRET_FILE" \
      -- uvx $argv >/dev/null || die "cannot register gws-$slug with Claude Code"
    printf 'registered: gws-%s -> %s\n' "$slug" "$email"
  done
}

cmd_claude_uninstall() {
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "$CLAUDE_BIN is not on PATH"
  local slug
  printf '%s\n' "$ACCOUNTS" | cut -f1 | while read -r slug; do
    if "$CLAUDE_BIN" mcp remove -s user "gws-$slug" >/dev/null 2>&1; then
      printf 'removed: gws-%s\n' "$slug"
    else
      printf 'absent:  gws-%s\n' "$slug"
    fi
  done
}

cmd_hermes_config() {
  local slug email argv
  argv=$(server_argv | tail -n +2 | paste -sd, - | sed 's/,/, /g')
  printf '# Google Workspace, one instance per account. Paste under mcp_servers in\n'
  printf '# cade/config/config.yaml, beside the existing exa block, then run ./check.sh\n'
  printf '# and ./deploy.sh --apply-config from that repo.\n'
  printf '# trust: untrusted matches the exa precedent and is right here: a mailbox is\n'
  printf '# the fleet position most exposed to text written by strangers.\n'
  printf '%s\n' "$ACCOUNTS" | while IFS=$'\t' read -r slug email; do
    printf '  gws-%s:\n' "$slug"
    printf '    # %s\n' "$email"
    printf '    command: uvx\n'
    printf '    args: [%s]\n' "$argv"
    printf '    env:\n'
    printf '      WORKSPACE_MCP_CREDENTIALS_DIR: %s/%s\n' "$ACCOUNTS_ROOT" "$slug"
    printf '      GOOGLE_CLIENT_SECRET_PATH: %s\n' "$CLIENT_SECRET_FILE"
    printf '    trust: untrusted\n'
  done
}

# delete_account_credentials removes only the exact credential file paths inside one
# account's own directory. It refuses an empty or unexpected directory outright, never
# expands a glob into a delete, and never touches anything above the accounts root.
delete_account_credentials() {
  local slug="${1:-}" dir expected f
  [ -n "$slug" ] || die "internal: no account slug to delete credentials for"
  expected="$ACCOUNTS_ROOT/$slug"
  dir="$expected"
  [ -n "$ACCOUNTS_ROOT" ] || die "internal: accounts root is unset"
  [ -d "$dir" ] || die "internal: $dir is not a directory"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    case "$f" in
      "$expected"/*) ;;
      *) die "internal: refusing to delete $f from outside $expected" ;;
    esac
    rm -- "$f" || die "cannot delete $f"
    printf 'deleted: %s\n' "$f"
  done <<EOF
$(credential_files "$dir")
EOF
}

cmd_revoke() {
  local account="${1:-}" yes="${2:-}" email dir held
  resolve_account "$account"
  email=$(account_email "$account")
  dir=$(creds_dir "$account")
  held=$(credential_emails "$dir" | paste -sd, -)
  if [ -z "$held" ]; then
    printf 'nothing to delete: %s holds no credentials\n' "$dir"
  elif [ "$yes" != "--yes" ]; then
    printf 'This deletes the stored Google credentials for %s in %s.\n' "$held" "$dir"
    printf 'Re-run with --yes to confirm.\n'
    return 1
  else
    delete_account_credentials "$(account_slug "$account")"
  fi
  printf '\nLocal deletion only stops this machine from using the account.\n'
  printf 'To end the grant itself, sign in as %s and remove the app here:\n' "$email"
  printf '  https://myaccount.google.com/connections\n'
}

case "${1:-}" in
  accounts)         shift; cmd_accounts "$@" ;;
  argv)             shift; server_argv ;;
  paths)            shift; cmd_paths "${1:-}" ;;
  init)             shift; cmd_init "$@" ;;
  client-secret)    shift; cmd_client_secret "$@" ;;
  auth)             shift; cmd_auth "${1:-}" ;;
  verify)           shift; cmd_verify "${1:-}" ;;
  status)           shift; cmd_status "$@" ;;
  claude-config)    shift; cmd_claude_config "$@" ;;
  claude-install)   shift; cmd_claude_install "$@" ;;
  claude-uninstall) shift; cmd_claude_uninstall "$@" ;;
  hermes-config)    shift; cmd_hermes_config "$@" ;;
  revoke)           shift; cmd_revoke "${1:-}" "${2:-}" ;;
  -h|--help|help)   usage ;;
  *)                usage >&2; exit 2 ;;
esac

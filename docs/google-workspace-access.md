# Google Workspace access

Gmail, Drive, Calendar, Docs, Sheets, and Contacts for Arjun's three Google accounts, reachable from both firstmate/Claude Code and Cade's Hermes.
`bin/fm-google-workspace.sh` owns the account table, the paths, and the exact invocation; its header and `--help` are authoritative for flags and mechanics.
`bin/fm-google-workspace-wizard.sh` walks the captain through the parts only he can do.

## Shape

One `google_workspace_mcp` instance per account, `--single-user`, each pointed at its own `WORKSPACE_MCP_CREDENTIALS_DIR`, over stdio.
The per-instance credentials directory is the account boundary, and that is the whole reason for the shape.
Nearly every tool this server exposes takes the target mailbox as an ordinary call argument, so one shared instance holding several accounts would leave the separation between them to a string the model emits.
A process holding only one account's directory cannot reach another mailbox whatever it is asked for.

Sapna's accounts are Nova-only and are deliberately absent from the account table, so no subcommand here can reach them.

## Accounts and their directories

| Account | Server name | Credentials directory |
| --- | --- | --- |
| `arjmad@gmail.com` | `gws-arjmad` | `~/.local/state/google-workspace-mcp/accounts/arjmad` |
| `arjun@ecomills.com` | `gws-ecomills` | `~/.local/state/google-workspace-mcp/accounts/ecomills` |
| `williamkempf@gmail.com` | `gws-kempf` | `~/.local/state/google-workspace-mcp/accounts/kempf` |

The root honours `XDG_STATE_HOME` and is overridden by `FM_GWS_ROOT`; run `bin/fm-google-workspace.sh paths` to print the resolved values rather than assuming them.
Directories are `0700` and the credential files the server writes inside them are `0600`.
The shared Desktop OAuth client lives beside them at `client_secret.json`, mode `0600`, and never in a repository.
Both runtimes read the same root, so one consent per account serves firstmate and Hermes together.

## The exact invocation

```
uvx workspace-mcp --single-user --permissions gmail:full drive:full calendar:full docs:full sheets:full contacts:full
```

Each instance additionally receives `WORKSPACE_MCP_CREDENTIALS_DIR` for its own account and `GOOGLE_CLIENT_SECRET_PATH` for the shared client.
`bin/fm-google-workspace.sh argv` prints this list, and the Claude Code and Hermes configurations are both generated from it, so the three cannot drift apart.

`--permissions` is the only flag that narrows the OAuth token itself.
`--tool-tier` and `--disabled-tools` shrink the registered tool list while still consenting to every scope the loaded services imply, so neither is a substitute.
`--permissions` is mutually exclusive with `--tools` and `--read-only`, which is why the service list above is expressed entirely as permission levels.

Upstream's own skill documents `uvx workspace-mcp --cli`, which the package does not implement; the real second entry point, `workspace-cli`, only talks to an already-running server.
Do not copy that invocation from upstream documentation.

## Send is authorized

The captain authorized send for these three accounts on 2026-08-29, so these instances deliberately do not run `--read-only`.
This is a change from the earlier draft-only posture, and it is what `gmail:full` buys.
Gmail has no scope that permits organizing without also permitting sending, so any level above `readonly` is send-capable at the token; the levels above it buy label, draft, and settings access rather than a narrower send.
The granted scopes are Gmail read/labels/modify/compose/send/settings-basic, Drive read and full, Calendar read/events/full, Docs read and write, Sheets read and write, Contacts read and full, plus `openid` and the two userinfo scopes.
The corresponding Cloud APIs, and no others, must be enabled: Gmail, Drive, Calendar, Docs, Sheets, and People.
People is the API behind Contacts.

A mailbox is the fleet position most exposed to text written by strangers, and under send authority a successful injection can send as the captain rather than only leave a draft.
The Hermes entries are therefore marked `trust: untrusted`, matching the existing convention there.

## First-time setup

Run `bin/fm-google-workspace-wizard.sh` and follow it.
It covers the Cloud project, the six APIs, the consent screen, the Desktop OAuth client, storing that client in Bitwarden, one sign-in per account, and registering the servers with Claude Code.
It is safe to stop and re-run: every stage is idempotent and reports what already exists.

`arjun@ecomills.com` is a Workspace account, so an `ecomills.com` administrator can block third-party OAuth apps outright.
If that sign-in is refused rather than merely warning about an unverified app, trust the client ID under Admin console, Security, Access and data control, API controls, Trusted by OAuth client ID.
The other two are personal accounts and cannot be blocked this way.

Cade's configuration lives in his own repository and is not edited from here.
`bin/fm-google-workspace.sh hermes-config` prints the exact block to paste under `mcp_servers` in `cade/config/config.yaml`, after which that repo's own `./check.sh` and `./deploy.sh --apply-config` apply it.

## Checking what is authorized

`bin/fm-google-workspace.sh status` reports each account as authorized, not yet authorized, or holding the wrong account.
The server names every credential file after the email in Google's verified ID token, so that file records which account actually signed in rather than which one was requested.
A directory holding an account other than its own is reported rather than ignored, because that is exactly the failure the per-account layout exists to prevent.

`bin/fm-google-workspace.sh verify <account>` proves an account still works by performing a real read and printing the account it read as.

## Re-authorizing an account

Run `bin/fm-google-workspace.sh auth <account>`, which is what the wizard calls.
An account already authorized is left alone and reported as such; a fresh consent replaces only that account's own tokens.
If the directory holds a different account, the command refuses rather than clearing it, and names the revoke step below as the deliberate way through.

A login expires after seven days if the OAuth consent screen was left in Testing rather than published to production; if all three accounts need re-authorizing weekly, that is the cause.

## Revoking an account

Revocation has two halves and both are needed.

Locally, `bin/fm-google-workspace.sh revoke <account> --yes` deletes that account's stored credentials.
It removes only the credential files inside that one account's directory, leaves the server's own bookkeeping and every other account untouched, and refuses without `--yes`.
This stops this machine from using the account; it does not end the grant.

At Google, sign in as that account and remove the app at <https://myaccount.google.com/connections>.
This ends the grant itself, including any copy of the tokens elsewhere.
Do both, in either order.

To stop a runtime from offering the account at all, also run `bin/fm-google-workspace.sh claude-uninstall` for Claude Code, or remove that server's block from Cade's config and redeploy it.

#!/usr/bin/env python3
"""Drive one Google Workspace MCP consent ceremony, or verify one already granted.

Run through bin/fm-google-workspace.sh, which owns the account table, the credentials
directory layout, and the exact workspace-mcp invocation passed after ``--``.

Why a resident MCP session rather than a one-shot tool call: in stdio single-user mode
the server hosts the OAuth callback itself, so the process must stay alive from the
moment the consent URL is issued until Google redirects back to it. A one-shot client
would tear the callback down before the human finished signing in.

Identity is never taken on trust. The server stores each credential under the email in
Google's verified ID token, so the credential filename is the account that actually
signed in. This script waits for a new credential file, reports the account that file
names, and fails when that is not the account the operator asked for - which is what
catches a wrong-account sign-in at the moment it happens rather than at first use.

This script prints no token, refresh token, or client secret, and it creates, moves,
and deletes nothing: a wrong-account result is reported for the operator to resolve.

Usage:
  fm-google-workspace-auth.py --mode auth|verify --email <addr> \
      --credentials-dir <dir> [--timeout <seconds>] -- <server argv...>
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import urllib.parse
from pathlib import Path

SAFE_ENV = ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR")
# A real read, cheap and available at every Gmail permission level from readonly up.
VERIFY_TOOL = "list_gmail_labels"
BOOKKEEPING = {"oauth_states"}


def log(message: str) -> None:
    print(message, flush=True)


def stored_accounts(directory: Path) -> set[str]:
    """Return the Google-verified accounts this credentials directory holds."""
    if not directory.is_dir():
        return set()
    found = set()
    for entry in directory.glob("*.json"):
        if not entry.is_file() or entry.stem in BOOKKEEPING:
            continue
        found.add(urllib.parse.unquote(entry.stem))
    return found


def child_config(argv: list[str], credentials_dir: Path, client_secret: str) -> dict:
    env = {name: os.environ[name] for name in SAFE_ENV if name in os.environ}
    env["WORKSPACE_MCP_CREDENTIALS_DIR"] = str(credentials_dir)
    env["GOOGLE_CLIENT_SECRET_PATH"] = client_secret
    return {
        "mcpServers": {
            "gws": {"command": argv[0], "args": list(argv[1:]), "env": env}
        }
    }


def result_text(result) -> str:
    parts = []
    for block in getattr(result, "content", []) or []:
        text = getattr(block, "text", None)
        if text:
            parts.append(text)
    return "\n".join(parts)


async def wait_for_new_credential(directory: Path, before: set[str], timeout: float) -> set[str]:
    """Poll for credentials that appeared after consent, up to *timeout* seconds."""
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        appeared = stored_accounts(directory) - before
        if appeared:
            return appeared
        await asyncio.sleep(1.0)
    return set()


async def run(args: argparse.Namespace, server_argv: list[str]) -> int:
    directory = Path(args.credentials_dir)
    client_secret = os.environ.get("GOOGLE_CLIENT_SECRET_PATH", "")
    if not client_secret or not Path(client_secret).is_file():
        log("error: GOOGLE_CLIENT_SECRET_PATH does not point at an OAuth client secret")
        return 1

    # Imported only once the inputs are known good, so a misconfigured run reports the
    # real problem instead of an import error from an environment it never needed.
    from fastmcp import Client

    before = stored_accounts(directory)
    already = args.email in before

    config = child_config(server_argv, directory, client_secret)
    async with Client(config) as client:
        if args.mode == "auth" and not already:
            log(f"Starting the Google consent flow for {args.email}.")
            log("Your browser will open Google's sign-in page.")
            log(f"Sign in as {args.email} - not as any other account - and approve the request.")
            started = await client.call_tool(
                "start_google_auth",
                {"service_name": "Google Workspace", "user_google_email": args.email},
            )
            for line in result_text(started).splitlines():
                if "Authorization URL:" in line:
                    log(line.strip())
            log(f"Waiting up to {int(args.timeout)}s for you to finish in the browser...")
            appeared = await wait_for_new_credential(directory, before, args.timeout)
            if not appeared:
                log(f"error: no credential arrived for {args.email} within the time limit")
                log("       nothing was changed; re-run this step when you are ready")
                return 1
            wrong = sorted(a for a in appeared if a != args.email)
            if wrong:
                log(f"error: signed in as {', '.join(wrong)}, not {args.email}")
                log(f"       that credential is now in {directory}, which must hold only {args.email}")
                log(f"       remove it with: bin/fm-google-workspace.sh revoke {args.email} --yes")
                return 1
            log(f"AUTHENTICATED: {args.email}")
        elif args.mode == "auth":
            log(f"AUTHENTICATED: {args.email} (already authorized; nothing was changed)")

        holders = stored_accounts(directory)
        if args.email not in holders:
            log(f"error: {directory} holds no credentials for {args.email}")
            return 1
        strangers = sorted(a for a in holders if a != args.email)
        if strangers:
            log(f"error: {directory} also holds {', '.join(strangers)}")
            log("       one directory per account is what keeps the accounts apart")
            return 1

        log(f"Verifying with a real read ({VERIFY_TOOL}) as {args.email}...")
        verified = await client.call_tool(VERIFY_TOOL, {"user_google_email": args.email})
        text = result_text(verified)
        if "ACTION REQUIRED" in text or "Authentication Needed" in text:
            log(f"error: {args.email} is not usable yet; Google still wants consent")
            return 1
        summary = next((ln.strip() for ln in text.splitlines() if ln.strip()), "(no output)")
        log(f"VERIFIED: {args.email} - {summary}")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--mode", choices=("auth", "verify"), required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--credentials-dir", required=True)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("server_argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    server_argv = args.server_argv
    if server_argv and server_argv[0] == "--":
        server_argv = server_argv[1:]
    if not server_argv:
        parser.error("the workspace-mcp argv is required after --")

    try:
        return asyncio.run(run(args, server_argv))
    except KeyboardInterrupt:
        log("cancelled; nothing was changed")
        return 130


if __name__ == "__main__":
    sys.exit(main())

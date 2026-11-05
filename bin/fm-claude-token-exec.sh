#!/usr/bin/env bash
# fm-claude-token-exec.sh - hand a pinned Claude worker the launching
# session's setup-token, then run the worker.
#
# Usage: fm-claude-token-exec.sh <token-file> <command> [<arg>...]
#
# bin/fm-spawn.sh writes <token-file> (0600, inside the task's private launch
# directory) only when bin/fm-worker-account-lib.sh's
# fm_worker_account_claude_token_carry says the worker is pinned to the
# launching session's own Claude root. This script reads the file, removes it,
# exports its content as CLAUDE_CODE_OAUTH_TOKEN, and execs `env <command>
# <arg>...`, so the token reaches the worker through its environment and never
# through an argument list, the pane, a task record, or the Herdr resume file,
# and it does not stay on disk once the worker starts.
#
# A missing or unusable file - a Herdr resume or a second run of the same
# launch, after the first run consumed it - starts the worker on the pinned
# root's stored login instead, with CLAUDE_CODE_OAUTH_TOKEN unset, and says so
# on stderr. Any CLAUDE_CODE_OAUTH_TOKEN the caller's environment carries is
# always dropped first, so only the handed-over file can supply one.
set -u

[ "$#" -ge 2 ] || {
  echo "usage: fm-claude-token-exec.sh <token-file> <command> [<arg>...]" >&2
  exit 2
}
file=$1
shift
unset CLAUDE_CODE_OAUTH_TOKEN
token=
if [ -f "$file" ] && [ ! -L "$file" ] && [ -O "$file" ]; then
  token=$(<"$file") || token=
  rm -f -- "$file" || echo "warning: could not remove the handed-over setup-token file $file; remove it by hand" >&2
fi
if [ -n "$token" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$token"
else
  echo "firstmate: no setup-token handed to this launch; the worker runs on its pinned account's stored login" >&2
fi
unset token
exec env "$@"

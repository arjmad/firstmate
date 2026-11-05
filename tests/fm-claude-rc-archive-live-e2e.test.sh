#!/usr/bin/env bash
# Opt-in credentialed live guard for bin/fm-claude-rc-archive.sh. The helper
# depends on what Claude Code writes and what the Remote Control API accepts,
# so this drives the installed Claude Code for real: an idle interactive
# session with Remote Control on and a bare --name, launched in a lab
# directory the way bin/fm-spawn.sh launches a worker, is killed with SIGKILL
# (the kill teardown's process reap can deliver before Claude archives itself),
# and the helper, given only the task id, the launch directory, and the
# account root, must find its session record and archive the entry the
# Claude app lists. It fails naming the Claude Code version when any link in
# that chain moved. No prompt is submitted, but the guard creates one Remote
# Control session in the signed-in account and deletes it again, so it stays
# opt-in. Refresh docs/verification/runtime-backends.md
# "Claude Remote Control archive" from this guard after a Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_RC_ARCHIVE_LIVE_E2E claude python3 curl jq

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-claude-rc-archive-live)
PROJECT="$LAB/project"
ID="rc-archive-live-$$"
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
API=${FM_CLAUDE_RC_API_BASE:-https://api.anthropic.com}
DRIVER_PID='' CLAUDE_PID='' BRIDGE=''

# One Remote Control API call on curl's stdin, authorized by the token the
# helper itself resolves for this root (keychain first on macOS).
rc_api() {  # <method> <path>
  local token
  # shellcheck source=bin/fm-claude-rc-archive.sh
  token=$(. "$ROOT/bin/fm-claude-rc-archive.sh" && rc_token "$CLAUDE_DIR" && printf '%s' "$RC_TOKEN") || token=''
  [ -n "$token" ] || fail "Claude Code $CLAUDE_VERSION: no unexpired stored OAuth token for $CLAUDE_DIR"
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS --config - --max-time 15 -X "$1" -H 'anthropic-version: 2023-06-01' \
        -H 'anthropic-beta: ccr-byoc-2025-07-29' "$API$2"
}

cleanup() {
  [ -z "$CLAUDE_PID" ] || kill -9 "$CLAUDE_PID" 2>/dev/null || true
  [ -z "$DRIVER_PID" ] || kill "$DRIVER_PID" 2>/dev/null || true
  [ -z "$BRIDGE" ] || rc_api DELETE "/v1/sessions/$BRIDGE" >/dev/null 2>&1 || true
  [ -z "$CLAUDE_PID" ] || rm -f "$CLAUDE_DIR/sessions/$CLAUDE_PID.json" "$CLAUDE_DIR/sessions/$CLAUDE_PID".*.key
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT"
# A pty driver: runs Claude without the inherited session markers (Claude
# refuses to nest, and a child-session marker turns Remote Control off),
# answers the folder-trust dialog by moving off "No, exit" and confirming, and
# otherwise just drains the screen into a log.
cat > "$LAB/drive.py" <<'PY'
import os, pty, re, select, sys, time
project, name, log = sys.argv[1:4]
for k in [k for k in os.environ if re.match(r"(CLAUDECODE|CLAUDE_CODE_|CLAUDE_PID|FM_)", k)]:
    os.environ.pop(k)
pid, fd = pty.fork()
if pid == 0:
    os.chdir(project)
    os.execvp("claude", ["claude", "--dangerously-skip-permissions",
                         "--settings", '{"remoteControlAtStartup":true}', "--name", name])
out, seen, answered = open(log, "ab"), b"", False
while True:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out.write(data); out.flush(); seen = (seen + data)[-20000:]
    if not answered and b"Itrustthisfolder" in re.sub(rb"\x1b\[[0-9;?<>]*[A-Za-z]|\s", b"", seen):
        time.sleep(0.5); os.write(fd, b"\x1b[B"); time.sleep(0.5); os.write(fd, b"\r"); answered = True
    if os.waitpid(pid, os.WNOHANG)[0]:
        break
PY
python3 -I "$LAB/drive.py" "$PROJECT" "$ID" "$LAB/screen.log" &
DRIVER_PID=$!

# Wait (about 90 seconds) for the session record to carry its Remote Control id.
i=0
while [ "$i" -lt 360 ]; do
  for f in "$CLAUDE_DIR"/sessions/*.json; do
    [ -f "$f" ] || continue
    line=$(jq -r --arg n "$ID" 'select(.name == $n and (.bridgeSessionId | type) == "string") | "\(.pid) \(.bridgeSessionId)"' "$f" 2>/dev/null) || line=''
    [ -z "$line" ] || { CLAUDE_PID=${line%% *}; BRIDGE=${line#* }; break 2; }
  done
  kill -0 "$DRIVER_PID" 2>/dev/null || break
  sleep 0.25
  i=$((i + 1))
done
if [ -z "$BRIDGE" ]; then
  tail -c 2000 "$LAB/screen.log" | tr -cd '[:print:]\n' >&2
  fail "Claude Code $CLAUDE_VERSION: no session record named $ID ever carried a bridgeSessionId in $CLAUDE_DIR/sessions"
fi

kill -9 "$CLAUDE_PID" 2>/dev/null || fail "Claude Code $CLAUDE_VERSION: could not kill pid $CLAUDE_PID"
wait "$DRIVER_PID" 2>/dev/null || true
DRIVER_PID=''
before=$(rc_api GET "/v1/sessions/$BRIDGE" | jq -r '.session_status // .status // empty')
[ -n "$before" ] || fail "Claude Code $CLAUDE_VERSION: the Remote Control API has no record of $BRIDGE"
[ "$before" != archived ] || fail "Claude Code $CLAUDE_VERSION: $BRIDGE was already archived after SIGKILL, so this guard proves nothing"

found=$("$ROOT/bin/fm-claude-rc-archive.sh" find "$ID" "$PROJECT" "$CLAUDE_DIR")
[ "$found" = "$(cd -P "$CLAUDE_DIR" && pwd -P)"$'\t'"$BRIDGE" ] \
  || fail "Claude Code $CLAUDE_VERSION: find printed '$found', want the killed session $BRIDGE"
report=$(printf '%s\n' "$found" | "$ROOT/bin/fm-claude-rc-archive.sh" archive "$ID" 2>&1)
[ "$report" = "archived Claude Remote Control session $BRIDGE for $ID" ] \
  || fail "Claude Code $CLAUDE_VERSION: archive reported '$report'"
after=$(rc_api GET "/v1/sessions/$BRIDGE" | jq -r '.session_status // .status // empty')
[ "$after" = archived ] \
  || fail "Claude Code $CLAUDE_VERSION: $BRIDGE reads '$after' after the archive, want archived"
pass "Claude Code $CLAUDE_VERSION: a SIGKILLed worker's Remote Control session ($before) is found by name and launch dir and archived"

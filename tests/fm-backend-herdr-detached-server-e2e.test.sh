#!/usr/bin/env bash
# tests/fm-backend-herdr-detached-server-e2e.test.sh - real Herdr check that a
# server fm_backend_herdr_server_ensure starts on Linux leads its own Unix
# session.
#
# Herdr saves a server as a machine only when it reports
# `detached_server_daemon`, which is getsid(0) == getpid() (upstream
# herdrdev/herdr#4205), so bin/backends/herdr.sh starts the server under
# util-linux setsid, inside firstmate.slice when the host uses it. This suite
# starts a real server in its own isolated lab session and reads the kernel
# fact (the server's session id equals its pid), the slice membership when the
# slice applies, and Herdr's own capability where the installed Herdr reports
# it. It skips off Linux and where setsid does not resolve, because the start
# is today's there.
#
# Safety: the session is a generated fm-lab-* lab session, and cleanup goes
# only through bin/fm-herdr-lab.sh teardown (tests/herdr-test-safety.sh), never
# a bare `herdr server stop`.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
unset FM_HERDR_SETSID_BIN
[ "$(uname -s)" = Linux ] || { echo "skip: the setsid server start is Linux-only"; exit 0; }
command -v setsid >/dev/null 2>&1 || { echo "skip: setsid not found, so the server keeps the plain start"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$(fm_herdr_lab_name detached-server)
export HERDR_SESSION="$SESSION"
cleanup_all() {
  [ -n "$SESSION" ] || return 0
  herdr_safe_stop_and_delete "$SESSION"
  SESSION=
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
# shellcheck source=bin/fm-linux-slice-lib.sh
. "$ROOT/bin/fm-linux-slice-lib.sh"

fm_backend_herdr_server_ensure "$SESSION" || fail "server_ensure did not start the lab session's server"

# The server is the one process whose arguments end in this session's own
# unique server command; its panes and clients carry other arguments.
pids=$(ps -eo pid=,args= | awk -v want="server --session $SESSION" '
  { args = $0; sub(/^ *[0-9]+ +/, "", args) }
  length(args) >= length(want) && substr(args, length(args) - length(want) + 1) == want { print $1 }
')
[ "$(printf '%s\n' "$pids" | grep -c .)" = 1 ] || fail "expected exactly one server process for $SESSION, got: ${pids:-none}"
server_pid=$pids
server_sid=$(ps -o sid= -p "$server_pid" | tr -d ' ')
[ "$server_sid" = "$server_pid" ] || fail "the server does not lead its own session: pid=$server_pid sid=${server_sid:-unknown}"
pass "real herdr: the server server_ensure starts leads its own Unix session (sid == pid $server_pid)"

fm_linux_slice_prefix
if [ "${#FM_LINUX_SLICE_PREFIX[@]}" -gt 0 ]; then
  grep -q 'firstmate\.slice' "/proc/$server_pid/cgroup" ||
    fail "setsid moved the server out of firstmate.slice: $(cat "/proc/$server_pid/cgroup")"
  pass "real herdr: the session-leading server stays in firstmate.slice"
else
  echo "note: this host does not use firstmate.slice (no lingering user manager), so slice membership was not checked" >&2
fi

status=$(fm_herdr_lab_cli "$SESSION" status server --json 2>/dev/null) || fail "could not read the lab server's status"
detached=$(printf '%s' "$status" | jq -r '(.capabilities // {}) | if has("detached_server_daemon") then .detached_server_daemon | tostring else "absent" end' 2>/dev/null)
case "$detached" in
  true) pass "real herdr: Herdr reports detached_server_daemon for the session-leading server" ;;
  absent) echo "note: herdr $(herdr --version 2>/dev/null) reports no detached_server_daemon capability; the session id check above is the proof" >&2 ;;
  *) fail "Herdr reports detached_server_daemon=$detached for a server that leads its own session: $status" ;;
esac

cleanup_all
trap - EXIT

#!/usr/bin/env bash
# Live guard for the Claude store lock that bin/fm-live-lab.sh forget-claude
# takes around its ~/.claude.json rewrite.
#
# forget-claude avoids losing a Claude session's write by taking the same lock
# Claude Code takes: a directory named <store>.lock, made with mkdir and stale
# once its mtime is 10 seconds old. That lock path is a vendor fact, so
# tests/fm-live-lab-forget-claude.test.sh can only pin forget-claude's side of
# it. This guard proves the other side against the installed Claude Code: with
# the lock held, a real `claude mcp add -s user` writes nothing, and it lands
# its write once the lock is released. It spends no model tokens, so it runs
# wherever claude, node, jq and timeout are installed; FM_CLAUDE_STORE_LOCK_LIVE=0 (or
# FM_LIVE=0) turns it off.
#
# Isolation: CLAUDE_CONFIG_DIR and HOME both point into a throwaway /tmp root,
# so the real ~/.claude.json and ~/.claude are never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_STORE_LOCK_LIVE claude node jq timeout

CLAUDE_VERSION=$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')
LAB=
cleanup() {
  [ -n "${PROBE_PID:-}" ] && kill "$PROBE_PID" 2>/dev/null
  [ -n "$LAB" ] && rm -rf -- "$LAB"
}
trap cleanup EXIT

LAB=$(mktemp -d /tmp/fm-claude-store-lock.XXXXXX) || fail "cannot create the temporary root"
STORE="$LAB/config/.claude.json"
mkdir -p "$LAB/config" "$LAB/home"
printf '{"projects": {}}\n' > "$STORE"

in_lab() {  # <command...>: run claude against the throwaway store only
  (cd "$LAB" && env HOME="$LAB/home" CLAUDE_CONFIG_DIR="$LAB/config" DISABLE_AUTOUPDATER=1 \
    timeout 60 "$@")
}
digest() { shasum -a 256 "$1" | awk '{print $1}'; }

# Claude's first start on an empty store records its initial fields without the
# lock, so prime the store first; the probe then exercises an ordinary write.
in_lab claude mcp add -s user fm-store-lock-prime -- /bin/true >"$LAB/prime.out" 2>&1 \
  || fail "Claude Code $CLAUDE_VERSION: priming the throwaway store failed: $(cat "$LAB/prime.out")"

mkdir "$STORE.lock"
node -e 'const t=Date.now()/1000+3600;require("node:fs").utimesSync(process.argv[1],t,t)' "$STORE.lock"
before=$(digest "$STORE")
in_lab claude mcp add -s user fm-store-lock-probe -- /bin/true >"$LAB/probe.out" 2>&1 &
PROBE_PID=$!
sleep 3
kill -0 "$PROBE_PID" 2>/dev/null \
  || fail "Claude Code $CLAUDE_VERSION: claude finished while $STORE.lock was held, so it no longer waits on that lock: $(cat "$LAB/probe.out")"
[ "$(digest "$STORE")" = "$before" ] \
  || fail "Claude Code $CLAUDE_VERSION: claude wrote the store while $STORE.lock was held"
rmdir "$STORE.lock"
wait "$PROBE_PID"
rc=$?
PROBE_PID=
expect_code 0 "$rc" "Claude Code $CLAUDE_VERSION: claude mcp add after the lock was released"
[ "$(jq -r '.mcpServers | has("fm-store-lock-probe")' "$STORE")" = true ] \
  || fail "Claude Code $CLAUDE_VERSION: claude did not land its write after the lock was released"
pass "Claude Code $CLAUDE_VERSION: a store write waits on <store>.lock and lands after release"

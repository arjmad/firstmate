#!/usr/bin/env bash
# Live guard for the Claude store lock that bin/fm-claude-store-lock.mjs takes
# for every firstmate ~/.claude.json rewrite (fm-claude-trust.sh on each Claude
# spawn and fm-live-lab.sh forget-claude).
#
# Those writers avoid losing a Claude session's write by taking the same lock
# Claude Code takes: a directory named <store>.lock, made with mkdir and stale
# once its mtime is 10 seconds old, keyed on the store path Claude was given
# even when that path is a symlink. Those are vendor facts, so
# tests/fm-claude-trust.test.sh and tests/fm-live-lab-forget-claude.test.sh can
# only pin firstmate's side. This guard proves the other side against the
# installed Claude Code: with the lock held, a real `claude mcp add -s user`
# writes nothing, and it lands its write once the lock is released; for a
# symlinked store it waits on the link's lock and not on the target's. It
# spends no model tokens, so it runs wherever claude, node, jq and timeout are
# installed; FM_CLAUDE_STORE_LOCK_LIVE=0 (or FM_LIVE=0) turns it off.
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
  if [ -n "${PROBE_PID:-}" ]; then
    kill "$PROBE_PID" 2>/dev/null
    wait "$PROBE_PID" 2>/dev/null
  fi
  [ -n "$LAB" ] && rm -rf -- "$LAB"
}
trap cleanup EXIT

LAB=$(mktemp -d /tmp/fm-claude-store-lock.XXXXXX) || fail "cannot create the temporary root"
STORE="$LAB/config/.claude.json"
mkdir -p "$LAB/config" "$LAB/home"
printf '{"projects": {}}\n' > "$STORE"

in_lab() {  # <command...>: run claude against the throwaway store only
  # exec, so a backgrounded call's PID is timeout's own and cleanup's TERM
  # reaches claude through it.
  (cd "$LAB" && exec env HOME="$LAB/home" CLAUDE_CONFIG_DIR="$LAB/config" DISABLE_AUTOUPDATER=1 \
    timeout 60 "$@")
}
digest() { cksum < "$1"; }

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

# A symlinked store: the lock beside the link holds Claude's write, and a lock
# beside the target does not.
TARGET="$LAB/dotfiles/.claude.json"
mkdir -p "$LAB/dotfiles"
mv "$STORE" "$TARGET"
ln -s "$TARGET" "$STORE"
mkdir "$STORE.lock"
node -e 'const t=Date.now()/1000+3600;require("node:fs").utimesSync(process.argv[1],t,t)' "$STORE.lock"
before=$(digest "$TARGET")
in_lab claude mcp add -s user fm-store-lock-link -- /bin/true >"$LAB/link.out" 2>&1 &
PROBE_PID=$!
sleep 3
kill -0 "$PROBE_PID" 2>/dev/null \
  || fail "Claude Code $CLAUDE_VERSION: claude finished while the symlinked store's $STORE.lock was held: $(cat "$LAB/link.out")"
[ "$(digest "$TARGET")" = "$before" ] \
  || fail "Claude Code $CLAUDE_VERSION: claude wrote a symlinked store while the link's lock was held"
rmdir "$STORE.lock"
wait "$PROBE_PID"
rc=$?
PROBE_PID=
expect_code 0 "$rc" "Claude Code $CLAUDE_VERSION: claude mcp add on a symlinked store after the lock was released"
[ "$(jq -r '.mcpServers | has("fm-store-lock-link")' "$TARGET")" = true ] \
  || fail "Claude Code $CLAUDE_VERSION: claude did not land its write in the symlink's target"
# Claude writes past a held lock after about 14 seconds anyway, so only a write
# about as prompt as an unlocked one proves the target's lock was not waited on.
started=$SECONDS
in_lab claude mcp add -s user fm-store-lock-baseline -- /bin/true >"$LAB/baseline.out" 2>&1 \
  || fail "Claude Code $CLAUDE_VERSION: an unlocked claude mcp add on a symlinked store failed: $(cat "$LAB/baseline.out")"
baseline=$((SECONDS - started))
mkdir "$TARGET.lock"
node -e 'const t=Date.now()/1000+3600;require("node:fs").utimesSync(process.argv[1],t,t)' "$TARGET.lock"
started=$SECONDS
in_lab claude mcp add -s user fm-store-lock-target -- /bin/true >"$LAB/target.out" 2>&1
rc=$?
elapsed=$((SECONDS - started))
rmdir "$TARGET.lock"
expect_code 0 "$rc" "Claude Code $CLAUDE_VERSION: claude mcp add on a symlinked store with a lock beside its target: $(cat "$LAB/target.out")"
[ "$elapsed" -lt $((baseline + 6)) ] \
  || fail "Claude Code $CLAUDE_VERSION: claude took ${elapsed}s (unlocked: ${baseline}s) with a lock beside the symlink's target, so it waited on that lock"
[ "$(jq -r '.mcpServers | has("fm-store-lock-target")' "$TARGET")" = true ] \
  || fail "Claude Code $CLAUDE_VERSION: claude did not write past a lock beside the symlink's target"
[ -L "$STORE" ] || fail "Claude Code $CLAUDE_VERSION: claude replaced the store symlink with a regular file"
pass "Claude Code $CLAUDE_VERSION: a symlinked store is locked beside the link, not beside its target"

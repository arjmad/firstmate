#!/usr/bin/env bash
# Behavior tests for bin/fm-live-lab.sh forget-claude: which roots it accepts,
# which Claude project entries it removes, and that its store rewrite takes the
# lock Claude Code itself takes, <store>.lock, so a Claude write cannot land
# between its read and its rename and be lost. Needs no tmux and no harness;
# every store is a sandboxed CLAUDE_CONFIG_DIR, never the real ~/.claude.json.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "ok - skipped: node is not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "ok - skipped: jq is not installed"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-live-lab-forget) || fail "fixture: no temp root"
LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
T="$TMP_ROOT/trust"
mkdir -p "$T"
export HOME="$TMP_ROOT/fakehome"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR

# forget-claude removes exactly the Claude project entries at or under its root,
# for a live test that spawns Claude workers without a lab record. Its root
# lives under /tmp whatever TMPDIR says, since forget-claude takes only a
# system temporary directory.
F=$(TMPDIR=/tmp fm_test_tmproot fm-live-lab-forget) || fail "fixture: no /tmp root"
mkdir -p "$T/forget-config" "$F/forget-root/home/wt" "$F/forget-unmarked"
: > "$F/forget-root/.fm-forget-claude"
cat > "$T/forget-config/.claude.json" <<JSON
{"numStartups": 3, "projects": {"$F/forget-root/home/wt": {"hasTrustDialogAccepted": true}, "$F/forget-root": {"hasTrustDialogAccepted": true}, "$F/forget-rootless": {"hasTrustDialogAccepted": true}, "/elsewhere": {"hasTrustDialogAccepted": true}}}
JSON
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude "$F/forget-root" 2>&1)
expect_code 0 "$?" "forget-claude succeeds on a disposable root"
assert_contains "$out" "2" "forget-claude reports the two entries it removed"
kept=$(jq -r '.projects | keys | sort | join(",")' "$T/forget-config/.claude.json")
[ "$kept" = "$F/forget-rootless,/elsewhere" ] || [ "$kept" = "/elsewhere,$F/forget-rootless" ] \
  || fail "forget-claude kept the wrong entries: $kept"
[ "$(jq -r '.numStartups' "$T/forget-config/.claude.json")" = 3 ] \
  || fail "forget-claude changed an unrelated store field"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" HOME="$F/forget-root" "$LIVE_LAB" forget-claude "$F/forget-root/" 2>&1)
expect_code 1 "$?" "forget-claude refuses the home directory as its root"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude / 2>&1)
expect_code 1 "$?" "forget-claude refuses / as its root"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude /private 2>&1)
expect_code 1 "$?" "forget-claude refuses /private, whose stripped form would match every entry"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude "$ROOT" 2>&1)
expect_code 1 "$?" "forget-claude refuses a root outside every temporary directory"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" TMPDIR=/ "$LIVE_LAB" forget-claude "$ROOT" 2>&1)
expect_code 1 "$?" "forget-claude does not trust the caller's TMPDIR as a temporary directory"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude "$F/forget-unmarked" 2>&1)
expect_code 1 "$?" "forget-claude refuses a root its creator did not mark, such as a live task's directory"
assert_contains "$out" ".fm-forget-claude" "the refusal names the missing marker"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude "$F/forget-missing" 2>&1)
expect_code 1 "$?" "forget-claude refuses a root that does not exist"
[ "$(jq -r '.projects | keys | length' "$T/forget-config/.claude.json")" = 2 ] \
  || fail "a refused forget-claude still changed the store"
out=$(CLAUDE_CONFIG_DIR="$T/forget-config" "$LIVE_LAB" forget-claude relative/root 2>&1)
expect_code 1 "$?" "forget-claude refuses a relative root"
pass "fm-live-lab.sh forget-claude removes only the Claude entries under its root"

# set_mtime <path> <seconds from now>: portable across GNU and BSD touch.
set_mtime() {
  node -e 'const t=Date.now()/1000+Number(process.argv[2]);require("node:fs").utimesSync(process.argv[1],t,t)' "$1" "$2"
}
digest() { cksum < "$1"; }

# lock_store <dir>: a store with one entry under the marked root and one outside.
lock_store() {
  mkdir -p "$1"
  cat > "$1/.claude.json" <<JSON
{"numStartups": 3, "projects": {"$F/forget-root/home/wt": {"hasTrustDialogAccepted": true}, "/elsewhere": {"hasTrustDialogAccepted": true}}}
JSON
}

# A Claude session holding the store lock is mid-write: forget-claude must wait
# for it rather than rename over the store, and must then rewrite from what that
# session wrote, so the session's write survives.
S="$T/lock-held"
lock_store "$S"
mkdir "$S/.claude.json.lock"
before=$(digest "$S/.claude.json")
CLAUDE_CONFIG_DIR="$S" "$LIVE_LAB" forget-claude "$F/forget-root" > "$T/held.out" 2>&1 &
held_pid=$!
sleep 1
kill -0 "$held_pid" 2>/dev/null || fail "forget-claude finished while another writer held the store lock: $(cat "$T/held.out")"
[ "$(digest "$S/.claude.json")" = "$before" ] || fail "forget-claude rewrote the store while another writer held its lock"
jq '.vendorWrite = true' "$S/.claude.json" > "$S/.claude.json.vendor" && mv "$S/.claude.json.vendor" "$S/.claude.json"
rmdir "$S/.claude.json.lock"
wait "$held_pid"
expect_code 0 "$?" "forget-claude succeeds once the store lock is released"
[ "$(cat "$T/held.out")" = 1 ] || fail "forget-claude should report exactly one removed entry: $(cat "$T/held.out")"
[ "$(jq -r '.vendorWrite' "$S/.claude.json")" = true ] || fail "the lock holder's write was lost"
[ "$(jq -r '.projects | keys | join(",")' "$S/.claude.json")" = /elsewhere ] || fail "forget-claude kept the wrong entries after waiting"
[ ! -e "$S/.claude.json.lock" ] || fail "forget-claude left the store lock behind"

# A lock no holder has refreshed for over 10 seconds is stale, as Claude Code
# treats it: forget-claude breaks it, does its rewrite, and releases it.
S="$T/lock-stale"
lock_store "$S"
mkdir "$S/.claude.json.lock"
set_mtime "$S/.claude.json.lock" -60
out=$(CLAUDE_CONFIG_DIR="$S" "$LIVE_LAB" forget-claude "$F/forget-root" 2>&1)
expect_code 0 "$?" "forget-claude breaks a stale store lock: $out"
[ "$(jq -r '.projects | keys | join(",")' "$S/.claude.json")" = /elsewhere ] || fail "forget-claude did not rewrite past a stale lock"
[ ! -e "$S/.claude.json.lock" ] || fail "forget-claude left the broken lock behind"
[ -z "$(find "$S" -name '.claude.json.lock.*')" ] || fail "forget-claude left the stale lock it moved aside"

# A lock that stays fresh past the wait fails closed: the store is untouched and
# the other writer's lock is left in place.
S="$T/lock-fresh"
lock_store "$S"
mkdir "$S/.claude.json.lock"
set_mtime "$S/.claude.json.lock" 3600
before=$(digest "$S/.claude.json")
out=$(CLAUDE_CONFIG_DIR="$S" "$LIVE_LAB" forget-claude "$F/forget-root" 2>&1)
expect_code 1 "$?" "forget-claude refuses while the store lock stays held"
assert_contains "$out" ".claude.json.lock" "the refusal names the held lock"
[ "$(digest "$S/.claude.json")" = "$before" ] || fail "a refused forget-claude changed a locked store"
[ -d "$S/.claude.json.lock" ] || fail "forget-claude removed a lock it did not hold"
pass "fm-live-lab.sh forget-claude rewrites the store only under Claude Code's own lock"

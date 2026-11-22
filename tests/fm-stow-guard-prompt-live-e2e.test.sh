#!/usr/bin/env bash
# Live guard for `bin/fm-stow-guard.sh prompt` against the installed Claude
# Code. The hook records a restart offer only when the UserPromptSubmit
# payload's prompt is /stow itself, so it rests on a vendor fact no stub can
# confirm: that a typed /stow reaches the hook as the text /stow. This guard
# runs one real `claude -p /stow` in a fixture primary checkout that carries
# this repo's tracked prompt registration and a stub stow skill, with the
# session lock and its session id recorded for that very process, and checks
# the offer the hook wrote. It submits a prompt, so it is opt-in:
#
#   FM_STOW_GUARD_PROMPT_LIVE=1 tests/fm-stow-guard-prompt-live-e2e.test.sh
#
# (or FM_LIVE=1). docs/verification/supervision.md "Helm refresh by /clear"
# records its dated result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_STOW_GUARD_PROMPT_LIVE claude jq

CLAUDE_VERSION=$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')
TMP_ROOT=$(fm_test_tmproot fm-stow-guard-prompt-live)
trap fm_test_cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TMUX HERDR_ENV HERDR_PANE_ID HERDR_SESSION

test_typed_stow_reaches_the_prompt_hook() {
  local root="$TMP_ROOT/primary" sid rc=0
  mkdir -p "$root/state" "$root/config" "$root/.claude/skills/stow"
  git init -q "$root"
  : > "$root/AGENTS.md"
  ln -s "$ROOT/bin" "$root/bin"
  printf 'tokens=100000000\nrestart=1\n' > "$root/config/stow-guard"
  printf -- '---\nname: stow\ndescription: Live guard stub.\n---\nReply with exactly the word STOW-OK and nothing else.\n' \
    > "$root/.claude/skills/stow/SKILL.md"
  # Only the tracked prompt registration, so no other hook of this repo runs.
  jq '{hooks: {UserPromptSubmit: [.hooks.UserPromptSubmit[] | .hooks |= map(select(.command | contains("fm-stow-guard.sh prompt"))) | select(.hooks | length > 0)]}}' \
    "$ROOT/.claude/settings.json" > "$root/.claude/settings.json"
  jq -e '.hooks.UserPromptSubmit[0].hooks | length == 1' "$root/.claude/settings.json" >/dev/null \
    || fail "the tracked settings hold no fm-stow-guard.sh prompt registration"
  sid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
  sid=$(printf '%s' "$sid" | tr '[:upper:]' '[:lower:]')
  printf '%s\n' "$sid" > "$root/state/.lock-session"

  # exec keeps the pid, so the lock names the Claude process itself. The pane
  # is only the environment the hook reads; nothing is typed into it.
  # shellcheck disable=SC2016 # the inner shell expands its own arguments.
  ( cd "$root" && TMUX_PANE=%0 timeout 300 bash -c 'printf "%s\n" "$$" > state/.lock; exec claude -p /stow --session-id "$1" --model haiku' _ "$sid" \
      </dev/null >"$TMP_ROOT/claude.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fail "Claude Code $CLAUDE_VERSION: claude -p /stow exited $rc: $(tail -n 5 "$TMP_ROOT/claude.out")"
  jq -e --arg sid "$sid" '.offer.sid == $sid and (.offer.at | type == "number")' "$root/state/.stow-guard.json" >/dev/null 2>&1 \
    || fail "Claude Code $CLAUDE_VERSION: a typed /stow recorded no offer: $(cat "$root/state/.stow-guard.json" 2>/dev/null) reply: $(tail -n 3 "$TMP_ROOT/claude.out")"
  printf 'evidence: Claude Code %s: /stow recorded %s, reply %s\n' \
    "$CLAUDE_VERSION" "$(jq -c .offer "$root/state/.stow-guard.json")" "$(tail -n 1 "$TMP_ROOT/claude.out")"
  pass "Claude Code $CLAUDE_VERSION: a typed /stow reaches the tracked prompt hook as /stow and records the lock session's offer"
}

fm_test_run test_typed_stow_reaches_the_prompt_hook

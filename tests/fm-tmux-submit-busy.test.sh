#!/usr/bin/env bash
# tests/fm-tmux-submit-busy.test.sh - regression: busy pane + pending composer
# after Enter retries must return "empty" (message queued), not "pending".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane)
    cat "$COMPOSER" 2>/dev/null
    # FM_FAKE_COMPOSER_NEXT models an ANIMATING pane: every capture after the
    # first returns the next frame. Unset means a frozen pane, which is exactly
    # the leftover-footer case the freshness re-read must reject.
    [ -z "${FM_FAKE_COMPOSER_NEXT:-}" ] || printf '%s\n' "$FM_FAKE_COMPOSER_NEXT" > "$COMPOSER"
    exit 0 ;;
  send-keys)
    shift; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) ;; Enter) is_enter=1 ;; esac; shift
    done
    if [ "$is_enter" = 1 ]; then
      [ -z "${FM_FAKE_SENT:-}" ] || printf 'Enter\n' >> "$FM_FAKE_SENT"
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$COMPOSER"
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_busy_pane_pending_returns_empty() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-accepted"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  # Pre-check: composer state should be pending (via function, not $()).
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "pre-check: composer state expected pending, got '$(cat "$vfile")'"
  # Now test the submit - write verdict to file to avoid nested $().
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane pending should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "proven pending should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns empty (message queued)"
}

test_idle_pane_pending_returns_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "idle-pane pending should return pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)"
}

test_busy_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy pane clears composer on first Enter - returns empty"
}

test_idle_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "idle-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane clears composer on first Enter - returns empty as before"
}

test_busy_pane_unknown_stays_unknown() {
  local dir fakebin composer vfile
  dir="$TMP_ROOT/busy-unknown"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "a busy pane must not convert an unsafe composer to empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy conversion is limited to proven pending input"
}

test_busy_pane_ambiguous_pending_retries_without_conversion() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-ambiguous-pending"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  : > "$sent"
  printf '╭────────────╮\n│ > fix  │\n╰────────────╯\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "ambiguous composer text should be pending-unproven, got '$(cat "$vfile")'"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "a busy pane must not convert pending-unproven to empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "pending-unproven should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: pending-unproven retries without busy conversion"
}

test_unrecognized_state_skips_busy_conversion() {
  local dir fakebin composer busy_called vfile
  dir="$TMP_ROOT/unrecognized-state"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  busy_called="$dir/busy-called"
  vfile="$dir/verdict"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  (
    # shellcheck disable=SC2329
    fm_tmux_composer_state() { printf 'future-state'; }
    # shellcheck disable=SC2329
    fm_pane_is_busy() { touch "$busy_called"; return 0; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  ) || fail "unrecognized-state submit check failed"
  [ "$(cat "$vfile")" = future-state ] \
    || fail "unrecognized state should be preserved, got '$(cat "$vfile")'"
  [ ! -e "$busy_called" ] \
    || fail "unrecognized state must not trigger busy conversion"
  pass "fm_tmux_submit_enter_core: unrecognized states skip busy conversion"
}

test_claude_busy_signature_uses_real_capture_shapes() {
  local dir fakebin composer FM_FAKE_COMPOSER_NEXT
  dir="$TMP_ROOT/claude-signature"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  # FM_FAKE_COMPOSER_NEXT (empty by default) makes the fake pane FROZEN: every
  # capture returns the same frame. Setting it makes the pane ANIMATE.
  FM_FAKE_COMPOSER_NEXT=""
  pane_busy() {
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      FM_FAKE_COMPOSER_NEXT="$FM_FAKE_COMPOSER_NEXT" \
      FM_BUSY_FOOTER_RECHECK_SECS=0.05 \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy "$2" "$3"' \
      _ "$ROOT" "$1" "${2:-}"
  }

  # Live Claude 2.1.220 capture 1: spinner glyph and word from one turn.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 1 should be busy"

  # Live Claude 2.1.220 capture 2: a later turn with a changed glyph and word.
  printf '✽ Proofing… (5s · thinking with high effort)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 2 should be busy"

  # Live Claude 2.1.220 capture 3: generation is idle while a foreground shell
  # tool remains active. The glyph, the past-tense word and the elapsed duration
  # all rotate, so only the shape is matched and an animating footer is busy.
  FM_FAKE_COMPOSER_NEXT='✽ Cooked for 10m 18s · 1 shell still running'
  printf '✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  pane_busy live-shell claude || fail "Claude running-shell footer should be busy"

  # Every observed glyph and past-tense word of the same footer, including a bare
  # middot, plural shells, and a trailing hint after the count.
  FM_FAKE_COMPOSER_NEXT='✶ Boogieing for 3m 1s · 2 shells still running · ctrl+o to expand'
  printf '✳ Boogieing for 3m 0s · 2 shells still running · ctrl+o to expand\n' > "$composer"
  pane_busy live-shell claude || fail "rotated glyph, plural shells and a trailing hint should be busy"
  FM_FAKE_COMPOSER_NEXT='· Improvising for 1m 3s · 1 shell still running'
  printf '· Improvising for 1m 2s · 1 shell still running\n' > "$composer"
  pane_busy live-shell claude || fail "bare-middot running-shell footer should be busy"

  # Freshness boundary: the running-shell footer is grafted onto a persistent
  # past-tense summary, so a FROZEN one (a killed or wedged harness) must NOT
  # report working - false-healthy suppresses recovery.
  FM_FAKE_COMPOSER_NEXT=""
  printf '✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  pane_busy frozen-shell claude && fail "a frozen running-shell footer must not read busy"

  # Freshness is proven from the FOOTER LINE itself, never the whole tail:
  # unrelated churn in the tail (a background writer, a human typing in the
  # composer) must not refresh a byte-identical frozen footer.
  FM_FAKE_COMPOSER_NEXT='background writer row 2
✻ Cooked for 10m 17s · 1 shell still running'
  printf 'background writer row 1\n✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  pane_busy churn-frozen-shell claude && fail "unrelated tail churn must not refresh a frozen footer"

  # ...while the same churn alongside a genuinely advancing footer stays busy.
  FM_FAKE_COMPOSER_NEXT='background writer row 2
✽ Brewed for 10m 19s · 1 shell still running'
  printf 'background writer row 1\n✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  pane_busy churn-live-shell claude || fail "an advancing footer amid tail churn should be busy"

  # A footer that has disappeared by the second sample means the turn ended.
  FM_FAKE_COMPOSER_NEXT='Thought for 10m 18s, ran 1 shell command'
  printf '✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  pane_busy finished-shell claude && fail "a footer replaced by a completed-shell summary must be idle"

  # The self-fresh spinner shapes are exempt: a single capture already proves a
  # streaming turn, so a repeated frame stays busy.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)\n' > "$composer"
  pane_busy frozen-spinner claude || fail "the spinner shape must not require a second sample"

  # Real idle Claude capture shapes from the same pane family.
  printf '✻ Worked for 31s\n' > "$composer"
  pane_busy idle claude && fail "Claude Worked-for capture must be idle"
  printf 'Thought for 9s, ran 1 shell command\n' > "$composer"
  pane_busy idle-shell claude && fail "Claude completed-shell summary must be idle"
  FM_FAKE_COMPOSER_NEXT='Thought for 10s, ran 2 shell commands'
  printf 'Thought for 9s, ran 1 shell command\n' > "$composer"
  pane_busy idle-shell claude && fail "a completed-shell summary must stay idle even while animating"
  FM_FAKE_COMPOSER_NEXT=""

  # The new signatures are Claude-scoped and must not widen the shared default.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens)\n' > "$composer"
  pane_busy live && fail "Claude spinner must not match without the Claude harness"
  FM_FAKE_COMPOSER_NEXT='✽ Cooked for 10m 18s · 1 shell still running'
  printf '✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  pane_busy live-shell && fail "Claude running-shell footer must not match without the Claude harness"
  pane_busy live-shell codex && fail "Codex must ignore Claude's running-shell footer"
  FM_FAKE_COMPOSER_NEXT=""

  # Each verified harness must use only its own signature.
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore OpenCode's interrupt footer"
  printf 'Working...\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore Pi's Working footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore OpenCode's interrupt footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross opencode && fail "OpenCode must ignore Grok's cancel footer"
  printf '⠦ Waiting · 2s\n' > "$composer"
  pane_busy cross opencode && fail "OpenCode must ignore Prime Agent's spinner"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross pi && fail "Pi must ignore OpenCode's interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy cross grok && fail "Grok must ignore Claude's legacy interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy own codex || fail "Codex's escape footer should be busy"
  printf 'esc interrupt\n' > "$composer"
  pane_busy own opencode || fail "OpenCode's interrupt footer should be busy"

  # No harness keeps the historical combined-pattern compatibility fallback.
  printf 'Working...\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Pi's shared signature"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Grok's shared signature"

  # A supplied harness must never use another harness's signature. This is
  # particularly important for Kimi: its idle key-tip rotation can include the
  # same cancel token Grok uses to mean busy.
  printf 'Working...\n' > "$composer"
  pane_busy unknown kimi && fail "Kimi must ignore Pi's Working footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy unknown kimi && fail "idle Kimi must ignore Grok's cancel footer"

  # Older Claude Code and the existing Pi and Grok signatures remain unchanged.
  printf 'esc to interrupt\n' > "$composer"
  pane_busy old-claude claude || fail "older Claude escape footer should be busy"
  printf 'Working...\n' > "$composer"
  pane_busy pi pi || fail "Pi Working footer should be busy"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy grok grok || fail "Grok cancel footer should be busy"
  printf '⠦ Waiting · 2s\n' > "$composer"
  pane_busy prime-wait prime-agent || fail "Prime Agent Waiting spinner should be busy"
  printf '  ⠏ Executing · 8s · ↑ 44 tokens\n' > "$composer"
  pane_busy prime-exec prime-agent || fail "Prime Agent Executing spinner should be busy"
  printf 'Waiting · 2s\n' > "$composer"
  pane_busy prime-idle prime-agent && fail "Prime Agent text without a spinner must not be busy"
  pass "fm_pane_is_busy: harness busy signatures are scoped, including Prime Agent"
}

# The freshness proof must be STRUCTURAL, not a convention a reader can skip.
# bin/fm-watch.sh, bin/fm-supervise-daemon.sh and bin/fm-pending-reply-lib.sh all
# classify from ONE capture through fm_busy_lines_match, and fm-watch.sh gates
# its whole stale block (including the .stale-since wedge timer) on a not-busy
# verdict. If the single-sample signature could see the running-shell footer, a
# killed Claude crew that froze the footer on screen would suppress its own
# wedge recovery, so the footer must be unreachable from that matcher.
test_claude_shell_footer_is_unreachable_from_single_sample_readers() {
  local footer='✻ Cooked for 10m 17s · 1 shell still running'
  unset FM_BUSY_REGEX
  if printf '%s' "$footer" | fm_busy_lines_match claude; then
    fail "the single-sample matcher must not credit Claude's persistent running-shell footer"
  fi
  case "$FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT" in
    *"still running"*) fail "the running-shell footer must stay out of the single-sample Claude signature" ;;
  esac
  # The self-fresh spinner shapes stay single-sample, so the recovery readers
  # keep every signature they had before the footer existed.
  printf '%s' '✢ Pollinating… (16s · ↓ 1.1k tokens)' | fm_busy_lines_match claude \
    || fail "the spinner shape must still match from a single sample"
  printf '%s' 'esc to interrupt' | fm_busy_lines_match claude \
    || fail "the legacy escape footer must still match from a single sample"

  # fm_busy_shell_footer_line is the sole reader of the footer signature, and is
  # scoped to the recorded Claude harness.
  [ "$(printf '%s' "$footer" | fm_busy_shell_footer_line claude)" = "$footer" ] \
    || fail "fm_busy_shell_footer_line should return the matched Claude footer line"
  [ -z "$(printf '%s' "$footer" | fm_busy_shell_footer_line codex)" ] \
    || fail "the running-shell footer must not be readable for another harness"
  [ -z "$(printf '%s' "$footer" | fm_busy_shell_footer_line)" ] \
    || fail "the running-shell footer must not be readable without a recorded harness"
  [ -z "$(printf '%s' 'Thought for 9s, ran 1 shell command' | fm_busy_shell_footer_line claude)" ] \
    || fail "a completed-shell summary is not a running-shell footer"
  [ -z "$(FM_BUSY_REGEX='esc to interrupt' fm_busy_shell_footer_line claude <<<"$footer")" ] \
    || fail "an explicit FM_BUSY_REGEX override owns the whole decision"
  pass "fm_busy_lines_match: the persistent running-shell footer is unreachable without a freshness proof"
}

# With no re-read there is no freshness proof, so the footer is not credited -
# `0` must never mean "trust it unchecked".
test_disabled_recheck_drops_the_shell_footer() {
  local dir fakebin composer
  dir="$TMP_ROOT/claude-recheck-disabled"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  printf '✻ Cooked for 10m 17s · 1 shell still running\n' > "$composer"
  if PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
     FM_FAKE_COMPOSER_NEXT='✽ Brewed for 10m 19s · 1 shell still running' \
     FM_BUSY_FOOTER_RECHECK_SECS=0 \
     bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy live-shell claude' _ "$ROOT"; then
    fail "a disabled re-read must drop the footer, not trust it unchecked"
  fi
  pass "fm_busy_decide: a disabled freshness re-read refuses the running-shell footer"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_busy_pane_unknown_stays_unknown
test_busy_pane_ambiguous_pending_retries_without_conversion
test_unrecognized_state_skips_busy_conversion
test_claude_busy_signature_uses_real_capture_shapes
test_claude_shell_footer_is_unreachable_from_single_sample_readers
test_disabled_recheck_drops_the_shell_footer

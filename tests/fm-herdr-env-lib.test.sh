#!/usr/bin/env bash
# Every Herdr execution seam scrubs Claude's inherited child-session marker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-env-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/herdr.log"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'child=%s session=%s args=%s\n' \
  "${CLAUDE_CODE_CHILD_SESSION-unset}" "${CLAUDE_CODE_SESSION_ID-unset}" "$*" >> "$FM_FAKE_HERDR_LOG"
printf '%s\n' '{"client":{"protocol":17}}'
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-env-lib.sh"
CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=keep \
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$LOG" \
  fm_herdr_scrubbed_exec herdr status --json >/dev/null
assert_contains "$(cat "$LOG")" 'child=unset session=keep args=status --json' \
  "the shared Herdr execution seam must remove only the harmful child-session marker"

: > "$LOG"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=keep \
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$LOG" \
  fm_backend_herdr_cli fm-lab-test status --json >/dev/null
assert_contains "$(cat "$LOG")" \
  'child=unset session=keep args=status --json --session fm-lab-test' \
  "the backend's session-scoped Herdr path must use the shared scrub"

pass "Herdr CLI execution removes CLAUDE_CODE_CHILD_SESSION without blanket-stripping Claude configuration"

#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-snapshot.sh.
#
# A fake quota-axi answers from the Claude account its CLAUDE_CONFIG_DIR
# selects, the way the real one does: the ambient (personal) account reads as
# measured at 14%, and the pinned worker root reads as unavailable because its
# login is in the Keychain. A fake claude answers `claude -p /usage` for the
# pinned root only. The cases prove dispatch evidence comes from the pinned
# worker account and never from the caller's own login.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-quota-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-snapshot)
HOME_DIR="$TMP_ROOT/home"
PIN_ROOT="$TMP_ROOT/claude-work"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/calls"
mkdir -p "$HOME_DIR/config" "$PIN_ROOT"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'quota-axi %s ccd=%s key=%s\n' "$*" "${CLAUDE_CONFIG_DIR-<unset>}" "${ANTHROPIC_API_KEY-<unset>}" >> "${FAKE_LOG:?}"
if [ "${CLAUDE_CONFIG_DIR-}" = "${FAKE_PIN_ROOT:?}" ] && [ "${FAKE_PIN_MEASURED:-0}" = 0 ]; then
  status=unknown avail='[]'
else
  status=known avail='[{"scope":"all_models","status":"known","effectivePercentRemaining":14,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}]'
fi
if [ "${1:-}" = --json ]; then
  printf '{"schemaVersion":%s,"providers":[{"provider":"claude"%s,"quotaSemantics":{"status":"%s","effectiveAvailability":%s}},{"provider":"codex"%s,"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.1}}]}}]}\n' \
    "${FAKE_SCHEMA:-5}" "$([ "${FAKE_SCHEMA:-5}" = 6 ] && printf ',"accountKey":"default"')" "$status" "$avail" \
    "$([ "${FAKE_SCHEMA:-5}" = 6 ] && printf ',"accountKey":"codex-home"')"
else
  printf 'quota[1]: claude %s\n' "$status"
fi
SH
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
printf 'claude %s ccd=%s key=%s\n' "$*" "${CLAUDE_CONFIG_DIR-<unset>}" "${ANTHROPIC_API_KEY-<unset>}" >> "${FAKE_LOG:?}"
[ "${FAKE_CLAUDE_FAIL:-0}" = 1 ] && exit 1
[ "$*" = "-p /usage" ] || exit 2
cat <<'OUT'
You are currently using your subscription to power your Claude Code usage

Current session: 2% used · resets Oct 4 at 9:49pm (America/New_York)
Current week (all models): 22% used · resets Oct 9 at 8:59pm (America/New_York)
Current week (Fable): 31% used · resets Oct 9 at 8:59pm (America/New_York)
OUT
SH
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/claude"

run() {  # <args...>
  rm -f "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FAKE_LOG="$LOG" FAKE_PIN_ROOT="$PIN_ROOT" \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/personal" ANTHROPIC_API_KEY=ambient-key "$TOOL" "$@"
}

claude_pct() { jq -c '[.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | {scope, pct: .effectivePercentRemaining}]'; }

# No pin: today's quota-axi read, byte for byte, in the caller's environment.
out=$(run --json)
assert_equals '[{"scope":"all_models","pct":14}]' "$(printf '%s' "$out" | claude_pct)" "no pin keeps quota-axi's own reading"
assert_contains "$(cat "$LOG")" "ccd=$TMP_ROOT/personal" "no pin leaves the caller's CLAUDE_CONFIG_DIR"
assert_not_contains "$(cat "$LOG")" "claude -p" "no pin never asks claude"

# Pinned to a Keychain-backed root: the claude row comes from the pinned account.
printf '%s\n' "$PIN_ROOT" > "$HOME_DIR/config/claude-account"
out=$(run --json)
assert_equals '[{"scope":"all_models","pct":78},{"scope":"model:fable","pct":69}]' "$(printf '%s' "$out" | claude_pct)" "the pinned account's /usage replaces the unmeasured claude row"
assert_not_contains "$out" '"effectivePercentRemaining":14' "the personal account's 14% never reaches dispatch"
assert_contains "$(cat "$LOG")" "quota-axi --json ccd=$PIN_ROOT key=<unset>" "quota-axi reads the pinned root with ranked credentials shed"
assert_contains "$(cat "$LOG")" "claude -p /usage ccd=$PIN_ROOT key=<unset>" "claude /usage reads the pinned root with ranked credentials shed"
assert_equals '50' "$(printf '%s' "$out" | jq '.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining')" "other providers are untouched"
assert_equals 'null' "$(printf '%s' "$out" | jq '[.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[].selection] | first')" "no spendPriority is invented"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"
if printf '%s\n' "$out" | fm_quota_json_valid; then pass "the overlaid snapshot is a valid schema-5 snapshot"; else fail "the overlaid snapshot is a valid schema-5 snapshot"; fi

out=$(FAKE_SCHEMA=6 run --json)
assert_equals '"default"' "$(printf '%s' "$out" | jq '.providers[] | select(.provider == "claude") | .accountKey')" "schema 6 keeps the default account key"
if printf '%s\n' "$out" | fm_quota_json_valid; then pass "the overlaid snapshot is a valid schema-6 snapshot"; else fail "the overlaid snapshot is a valid schema-6 snapshot"; fi

# A pinned root quota-axi can measure keeps quota-axi's row and its spendPriority.
out=$(FAKE_PIN_MEASURED=1 run --json)
assert_not_contains "$(cat "$LOG")" "claude -p" "a measured pinned row never asks claude"

# An unreadable /usage leaves the row unmeasured rather than borrowing another account.
out=$(FAKE_CLAUDE_FAIL=1 run --json)
assert_equals '[]' "$(printf '%s' "$out" | claude_pct)" "a failed /usage leaves the pinned row unmeasured"

# TOON: quota-axi's TOON under the pin plus the pinned_claude block.
out=$(run)
assert_contains "$out" 'quota[1]: claude unknown' "TOON is quota-axi's under the pin"
assert_contains "$out" "pinned_claude: worker account $PIN_ROOT" "TOON names the pinned account"
assert_contains "$out" '  all_models: 78% remaining (session 98%, week 78%)' "TOON carries the all-model remaining"
assert_contains "$out" '  model:fable: 69% remaining (week 69%)' "TOON carries the model remaining"

# ordinary pins the vendor default: CLAUDE_CONFIG_DIR unset.
printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
out=$(run --json)
assert_contains "$(cat "$LOG")" "quota-axi --json ccd=<unset>" "ordinary unsets CLAUDE_CONFIG_DIR"

# A malformed pin refuses rather than reading the ambient account.
printf 'relative\n' > "$HOME_DIR/config/claude-account"
code=0
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FAKE_LOG="$LOG" FAKE_PIN_ROOT="$PIN_ROOT" "$TOOL" --json >/dev/null 2>&1 || code=$?
assert_equals 2 "$code" "a malformed pin refuses"

printf "# all fm-quota-snapshot tests passed\n"

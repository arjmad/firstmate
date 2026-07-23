#!/usr/bin/env bash
# Static regression coverage for tracked script inventory, usage headers,
# configurable limits, backend version claims, and skill trigger declarations.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCS_SCRIPTS="$ROOT/docs/scripts.md"
X_FOLLOWUP="$ROOT/bin/fm-x-followup.sh"
CMUX_DOC="$ROOT/docs/cmux-backend.md"
AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP_SKILL="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
STOW_SKILL="$ROOT/.agents/skills/stow/SKILL.md"

assert_contains_text() {
  local file=$1 text=$2 message=$3
  grep -Fq -- "$text" "$file" || fail "$message"
}

assert_absent_text() {
  local file=$1 text=$2 message=$3
  if grep -Fq -- "$text" "$file"; then
    fail "$message"
  fi
}

test_scripts_inventory_is_complete() {
  local program
  for program in \
    fm-cd-pretool-check.sh \
    fm-cd-command-policy.mjs \
    fm-transition-lib.sh \
    fm-install-shellcheck.sh \
    fm-lint.sh \
    backends/herdr-eventwait.py \
    backends/herdr-workspace-move.py
  do
    assert_contains_text "$DOCS_SCRIPTS" "\`$program\`" "docs/scripts.md must list $program"
  done
  pass "docs/scripts.md lists the seven previously omitted programs"
}

test_source_and_poll_headers_describe_interfaces() {
  assert_contains_text "$ROOT/bin/fm-check-lib.sh" 'fm-pr-lib.sh' "fm-check-lib header must declare its sourced dependency"
  assert_contains_text "$ROOT/bin/fm-check-lib.sh" 'fm_custom_check_snapshot_prepare' "fm-check-lib header must name its public snapshot API"
  assert_contains_text "$ROOT/bin/fm-pr-poll.sh" 'fm-pr-poll.sh --validated <url> <owner> <repo> <number>' "fm-pr-poll header must document validated mode"
  assert_contains_text "$ROOT/bin/fm-pr-poll.sh" '<task>.check.sh' "fm-pr-poll header must document installed-check mode"
  assert_contains_text "$ROOT/bin/fm-wake-lib.sh" 'then creates STATE immediately' "fm-wake-lib header must disclose its source-time mutation"
  assert_contains_text "$ROOT/bin/fm-wake-lib.sh" 'durable queue append/restore/deduplication' "fm-wake-lib header must summarize its public sourced API"
  pass "source libraries and PR poll document their interfaces and side effects"
}

test_x_followup_documents_configurable_cap() {
  assert_absent_text "$X_FOLLOWUP" 'up to three' "fm-x-followup header must not state a fixed cap"
  assert_absent_text "$X_FOLLOWUP" 'up to 3 per link' "fm-x-followup help must not state a fixed cap"
  assert_contains_text "$X_FOLLOWUP" 'FMX_FOLLOWUP_MAX_COUNT and FMX_FOLLOWUP_MAX_AGE_SECS configure them.' "fm-x-followup help must name both limit overrides"
  pass "fm-x-followup describes configurable limits"
}

test_cmux_minimum_matches_major_minor_gate() {
  assert_contains_text "$CMUX_DOC" 'version 0.64 or newer.' "cmux setup must state the implemented 0.64 minimum"
  assert_absent_text "$CMUX_DOC" 'version 0.64.17 or newer.' "cmux setup must not require the verification patch version"
  pass "cmux documentation matches the implemented major/minor minimum"
}

test_skill_triggers_match_agents_declarations() {
  assert_contains_text "$AGENTS" "When the captain invokes \`/bearings\` or asks for a bearings report" "AGENTS.md must declare the bearings trigger"
  if sed -n '/^## 13\./,/^## 14\./p' "$AGENTS" | grep -Fq -- 'bearings'; then
    fail "AGENTS.md section 13 must stay agent-only and not carry the bearings trigger"
  fi
  assert_absent_text "$BOOTSTRAP_SKILL" 'standalone bin/fm-bootstrap.sh' "bootstrap-diagnostics frontmatter must stay session-start scoped"
  assert_contains_text "$STOW_SKILL" 'or periodically to keep operational memory current' "stow frontmatter must declare the periodic trigger"
  assert_contains_text "$AGENTS" "before a session reset or context compaction, or periodically to keep operational memory current, load the \`stow\` skill" "AGENTS.md /stow line must declare the pre-reset and periodic triggers"
  pass "bearings, bootstrap-diagnostics, and stow triggers align with AGENTS.md"
}

test_scripts_inventory_is_complete
test_source_and_poll_headers_describe_interfaces
test_x_followup_documents_configurable_cap
test_cmux_minimum_matches_major_minor_gate
test_skill_triggers_match_agents_declarations

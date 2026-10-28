#!/usr/bin/env bash
# Behavioral coverage for bin/fm-agents-md-budget.sh: the repository's AGENTS.md
# stays under Codex's project-doc byte budget minus the safety margin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-agents-md-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-agents-md-budget)

write_bytes() {  # <path> <count>
  head -c "$2" /dev/zero | tr '\0' 'a' > "$1"
}

test_repository_agents_md_fits_codex_budget() {
  local out
  out=$("$CHECK" 2>&1) || fail "AGENTS.md exceeds the Codex budget minus margin: $out"
  assert_contains "$out" "fm-agents-md-budget: ok bytes=" "check did not report the measured size"
  assert_contains "$out" "budget=32768 margin=2048" "default budget is not Codex's 32 KiB minus a 2 KiB margin"
  pass "repository AGENTS.md fits Codex's project-doc budget with margin"
}

test_limit_boundary_is_budget_minus_margin() {
  local file="$TMP_ROOT/AGENTS.md" out rc
  write_bytes "$file" 900
  out=$("$CHECK" --file "$file" --budget 1000 --margin 100 2>&1) \
    || fail "a file exactly at the limit was refused: $out"
  assert_contains "$out" "bytes=900 limit=900" "boundary size was not reported"
  assert_contains "$out" "headroom=0" "boundary headroom was not reported"

  write_bytes "$file" 901
  out=$("$CHECK" --file "$file" --budget 1000 --margin 100 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "one byte over the limit exited $rc, want 1"
  assert_contains "$out" "is 901 bytes, 1 over the 900-byte limit" "overrun was not explained"
  pass "the limit is the budget minus the margin, inclusive"
}

test_counts_bytes_not_characters() {
  local file="$TMP_ROOT/multibyte.md" out
  # Ten copies of a three-byte character: 30 bytes but 10 characters.
  printf '%s' '€€€€€€€€€€' > "$file"
  out=$("$CHECK" --file "$file" --budget 40 --margin 20 2>&1)
  assert_contains "$out" "is 30 bytes, 10 over the 20-byte limit" "multibyte text was not measured in bytes"
  pass "size is measured in bytes, as Codex truncates"
}

test_invalid_arguments_refuse() {
  local rc
  "$CHECK" --budget 12k >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "non-numeric budget exited $rc, want 2"
  "$CHECK" --budget 100 --margin 100 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "margin equal to budget exited $rc, want 2"
  "$CHECK" --file "$TMP_ROOT/missing.md" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "missing file exited $rc, want 2"
  pass "malformed budget, margin, or file refuses instead of passing"
}

test_repository_agents_md_fits_codex_budget
test_limit_boundary_is_budget_minus_margin
test_counts_bytes_not_characters
test_invalid_arguments_refuse

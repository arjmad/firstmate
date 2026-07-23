#!/usr/bin/env bash
# Contract tests for the standard behavior-test runners in CI, no-mistakes, and
# CONTRIBUTING.md. They pin executable shell-test enforcement and discovery of
# both shell and Python behavior tests so either class cannot silently disappear.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
CONTRIBUTING="$ROOT/CONTRIBUTING.md"


test_all_shell_behavior_tests_are_executable() {
  local test_script
  for test_script in "$ROOT"/tests/*.test.sh; do
    [ -x "$test_script" ] || fail "shell behavior test is not executable: ${test_script#"$ROOT"/}"
  done
  pass "all shell behavior tests are executable for CI direct invocation"
}

# These fixed-string config assertions intentionally contain literal shell variables.
# shellcheck disable=SC2016
test_ci_guards_modes_and_runs_both_test_classes() {
  assert_grep 'if [ ! -x "$test_script" ]; then' "$CI" "CI must reject a non-executable shell behavior test"
  grep -Fqx '            "$test_script"' "$CI" || fail "CI must invoke shell behavior tests directly"
  assert_grep 'for test_script in tests/*.test.py; do' "$CI" "CI must discover Python behavior tests"
  assert_grep 'python3 "$test_script"' "$CI" "CI must run Python behavior tests"
  pass "CI enforces shell modes and runs shell plus Python behavior tests"
}

# shellcheck disable=SC2016
test_local_and_gate_commands_run_both_test_classes() {
  assert_grep 'for test_script in tests/*.test.py; do python3 "$test_script"; done' "$CONTRIBUTING" \
    "CONTRIBUTING.md must include the Python behavior-test loop"
  assert_grep 'for t in tests/*.test.sh;' "$NM" "no-mistakes must discover shell behavior tests"
  assert_grep 'for t in tests/*.test.py;' "$NM" "no-mistakes must discover Python behavior tests"
  assert_grep 'python3 "$t" || rc=1' "$NM" "no-mistakes must preserve Python test failures"
  pass "local and no-mistakes commands run shell plus Python behavior tests"
}

test_all_shell_behavior_tests_are_executable
test_ci_guards_modes_and_runs_both_test_classes
test_local_and_gate_commands_run_both_test_classes

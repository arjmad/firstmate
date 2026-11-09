#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-plan.sh: plan reduces a pull request to the
# behavior scripts and lint roots its committed change touches, or falls back
# to the full suite with a reason; gate turns that plan into each CI check's
# run or no-op from the check's own membership. Every case runs the real
# planner and its owners inside a throwaway git copy of this working tree, so
# the plans are the ones CI would compute for that change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP_ROOT=$(fm_test_tmproot fm-ci-plan)
COPY="$TMP_ROOT/repo"

commit_all() {
  git -C "$COPY" add -A
  git -C "$COPY" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"
}

mkdir -p "$COPY"
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard \
  | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
  | tar --null -T - -cf -) | tar -xf - -C "$COPY" || fail "could not copy the working tree"
git -C "$COPY" init -q
# A source chain top -> consumer -> probe that no real script forms. Names and
# source commands go through printf arguments so this file's own text never
# reads as a source edge or a path reference to the planner it tests.
PROBE=fm-zz-probe.sh CONSUMER=fm-zz-consumer.sh TOP=fm-zz-top.sh
printf '#!/usr/bin/env bash\nprobe() { :; }\n' >"$COPY/bin/$PROBE"
# shellcheck disable=SC2016  # literal fixture text
printf '#!/usr/bin/env bash\n# shellcheck source=bin/%s\n%s "$(dirname "$0")/%s"\n' "$PROBE" . "$PROBE" >"$COPY/bin/$CONSUMER"
# shellcheck disable=SC2016  # literal fixture text
printf '#!/usr/bin/env bash\n[ -n "${X:-}" ] && %s "$(dirname "$0")/%s"\n' . "$CONSUMER" >"$COPY/bin/$TOP"
printf '\n# bin/%s\n' "$PROBE" >>"$COPY/tests/fm-noticed.test.sh"
chmod +x "$COPY"/bin/fm-zz-*.sh
commit_all base
BASE=$(git -C "$COPY" rev-parse HEAD)
PLANNER="$COPY/bin/fm-ci-plan.sh"

reset_copy() {
  git -C "$COPY" reset -q --hard "$BASE"
  git -C "$COPY" clean -qfd
}

plan_pr() {
  "$PLANNER" plan --event pull_request --base "$BASE" "$@"
}

lanes() {
  "$COPY/bin/fm-test-run.sh" --list-lanes | grep -vx portable-serial
}

gate_table() {
  local plan=$1 lane k out
  rm -f "$TMP_ROOT"/only-*
  while IFS= read -r lane; do
    out=$(FM_CI_PLAN=$plan "$PLANNER" gate lane "$lane" --only-out "$TMP_ROOT/only-$lane") \
      || fail "gate lane $lane failed under $plan"
    printf '%s %s\n' "$lane" "$(printf '%s\n' "$out" | sed -n 's/^run=//p')"
  done < <(lanes)
  for k in 1 2 3 4 5 6 7 8; do
    out=$(FM_CI_PLAN=$plan "$PLANNER" gate lint "${k}of8") || fail "gate lint ${k}of8 failed"
    printf 'lint-%sof8 %s\n' "$k" "${out#run=}"
  done
  out=$(FM_CI_PLAN=$plan "$PLANNER" gate macos) || fail "gate macos failed"
  printf 'macos %s\n' "${out#run=}"
}

running() { printf '%s\n' "$1" | awk '$2 == "true" { print $1 }'; }

lane_of() {
  local lane
  while IFS= read -r lane; do
    "$COPY/bin/fm-test-run.sh" --list --lane "$lane" | grep -qxF "$1" && { printf '%s\n' "$lane"; return 0; }
  done < <(lanes)
  return 1
}

partition_of() {
  local k
  for k in 1 2 3 4 5 6 7 8; do
    "$COPY/bin/fm-lint.sh" --partition "${k}of8" --list-files | grep -qxF "$1" && { printf 'lint-%sof8\n' "$k"; return 0; }
  done
  return 1
}

assert_full() {
  local plan=$1 reason=$2
  [ "$(printf '%s' "$plan" | jq -r .mode)" = full ] || fail "expected a full plan, got: $plan"
  assert_contains "$(printf '%s' "$plan" | jq -r '.reasons[]')" "$reason" "full plan does not give the reason '$reason'"
  [ "$(printf '%s' "$plan" | jq '(.tests | length) + (.lint_roots | length)')" = 0 ] \
    || fail "a full plan must carry no selection: $plan"
}

test_single_test_change_runs_only_that_script_in_its_lane() {
  local plan table lane want
  reset_copy
  printf '\n# touched\n' >>"$COPY/tests/fm-ask-user-authority.test.sh"
  commit_all one-test
  plan=$(plan_pr) || fail "plan failed"
  [ "$(printf '%s' "$plan" | jq -c '[.mode, .tests]')" = '["affected",["tests/fm-ask-user-authority.test.sh"]]' ] \
    || fail "a one-test change must select only that test: $plan"
  lane=$(lane_of tests/fm-ask-user-authority.test.sh) || fail "the test is in no lane"
  table=$(gate_table "$plan")
  want=$(printf '%s\n' "$lane" "$(partition_of tests/fm-ask-user-authority.test.sh)" macos | LC_ALL=C sort)
  [ "$(running "$table" | LC_ALL=C sort)" = "$want" ] \
    || fail "only its lane, its lint partition and macOS may run, got: $(running "$table" | tr '\n' ' ')"
  [ "$(cat "$TMP_ROOT/only-$lane")" = tests/fm-ask-user-authority.test.sh ] \
    || fail "the lane's only file must hold exactly the changed test"
  pass "a single test change runs that one script in its lane and lints only its partition"
}

test_unreferenced_document_runs_only_the_prose_check() {
  local plan table lane page
  reset_copy
  # Built at run time: a literal path here would make this suite its reader.
  page="docs/zz-orphan-$$.md"
  printf '# New page\n\nNothing names this page.\n' >"$COPY/$page"
  commit_all docs-only
  plan=$(plan_pr) || fail "plan failed"
  [ "$(printf '%s' "$plan" | jq -c '[.mode, .tests, .lint_roots]')" = '["affected",["tests/fm-documentation-audiences.test.sh"],[]]' ] \
    || fail "an unreferenced document must select only the prose check and no lint root: $plan"
  lane=$(lane_of tests/fm-documentation-audiences.test.sh) || fail "the prose check is in no lane"
  table=$(gate_table "$plan")
  [ "$(running "$table" | LC_ALL=C sort)" = "$(printf '%s\n' "$lane" macos | LC_ALL=C sort)" ] \
    || fail "a docs-only change must leave every lint partition and other lane a no-op, got: $(running "$table" | tr '\n' ' ')"
  pass "an unreferenced document no-ops lint and every lane except the prose check's"
}

test_bin_change_lints_its_partition_and_every_sourcer() {
  local plan roots table part root
  reset_copy
  printf '# touched\n' >>"$COPY/bin/fm-zz-probe.sh"
  commit_all probe
  plan=$(plan_pr) || fail "plan failed"
  [ "$(printf '%s' "$plan" | jq -r .mode)" = affected ] || fail "a narrow bin change must stay affected: $plan"
  roots=$(printf '%s' "$plan" | jq -r '.lint_roots[]')
  [ "$roots" = "$(printf '%s\n' bin/fm-zz-consumer.sh bin/fm-zz-probe.sh bin/fm-zz-top.sh)" ] \
    || fail "lint roots must be the changed file and its direct and transitive sourcers, got: $roots"
  table=$(gate_table "$plan")
  for root in bin/fm-zz-probe.sh bin/fm-zz-consumer.sh bin/fm-zz-top.sh; do
    part=$(partition_of "$root") || fail "$root is in no lint partition"
    printf '%s\n' "$table" | grep -qx "$part true" || fail "$part holds $root but does not run"
  done
  [ "$(running "$table" | grep -c '^lint-')" -lt 8 ] || fail "a narrow bin change must leave some lint partition a no-op"
  pass "a bin change lints the partitions of its file and of every root that sources it"
}

test_full_triggers_give_their_reason() {
  local plan i unmapped
  reset_copy
  plan=$(plan_pr --labels docs,full-ci) || fail "plan failed"
  assert_full "$plan" "label full-ci"
  plan=$("$PLANNER" plan --event push) || fail "plan failed"
  assert_full "$plan" "event push"
  plan=$("$PLANNER" plan --event workflow_dispatch) || fail "plan failed"
  assert_full "$plan" "event workflow_dispatch"

  printf '\n' >>"$COPY/.github/workflows/ci.yml"
  commit_all workflow
  assert_full "$(plan_pr)" "full-suite path .github/workflows/ci.yml"

  reset_copy
  printf '\n' >>"$COPY/bin/fm-wake-lib.sh"
  commit_all lib
  assert_full "$(plan_pr)" "full-suite path bin/fm-wake-lib.sh"

  reset_copy
  printf '\n# touched\n' >>"$COPY/bin/fm-backend.sh"
  commit_all broad
  assert_full "$(plan_pr)" "broadly sourced bin/fm-backend.sh"

  reset_copy
  for i in $(seq 1 26); do printf 'page %s\n' "$i" >"$COPY/docs/zz-page-$i.md"; done
  commit_all many
  plan=$(plan_pr)
  assert_full "$plan" "26 changed files is more than 25"
  [ "$(printf '%s' "$plan" | jq '[.changed_count, (.changed | length)] | join(" ")' -r)" = "26 25" ] \
    || fail "a full plan must count every changed path but list at most 25: $plan"

  reset_copy
  git -C "$COPY" rm -q bin/fm-zz-top.sh
  commit_all delete
  assert_full "$(plan_pr)" "deleted bin/fm-zz-top.sh"

  reset_copy
  unmapped="zz-unmapped-$$.dat"
  printf 'data\n' >"$COPY/$unmapped"
  commit_all unmapped
  assert_full "$(plan_pr)" "no changed-test mapping for source path: $unmapped"

  reset_copy
  assert_full "$("$PLANNER" plan --event pull_request --base no-such-ref)" "error: base ref not found"
  pass "events, the full-ci label, trigger paths, broad sources, size, deletions, unmapped paths and errors plan the full suite"
}

test_full_plan_runs_every_check_whole() {
  local plan table
  reset_copy
  plan=$("$PLANNER" plan --event push) || fail "plan failed"
  table=$(gate_table "$plan")
  [ -z "$(printf '%s\n' "$table" | awk '$2 != "true"')" ] || fail "a full plan must run every check: $table"
  [ -z "$(find "$TMP_ROOT" -maxdepth 1 -name 'only-*' -print -quit)" ] \
    || fail "a full plan must not narrow any lane"
  pass "a full plan runs every lint partition, lane and macOS whole"
}

test_gate_refuses_a_missing_malformed_or_stale_plan() {
  local plan rc
  reset_copy
  plan=$(plan_pr) || fail "plan failed"
  FM_CI_PLAN='' "$PLANNER" gate macos >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "a missing plan must exit 2, got $rc"
  FM_CI_PLAN='{"version":9}' "$PLANNER" gate lane portable-parallel-1 >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "a malformed plan must exit 2, got $rc"
  printf '\n# later\n' >>"$COPY/tests/fm-ask-user-authority.test.sh"
  commit_all later
  FM_CI_PLAN=$plan "$PLANNER" gate lint 1of8 >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "a plan for another commit must exit 2, got $rc"
  FM_CI_PLAN=$(plan_pr) "$PLANNER" gate lint 9of8 >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "a partition the lint owner refuses must exit 2, got $rc"
  pass "gate exits 2 on a missing, malformed or stale plan and on a refused shard"
}

test_gate_writes_github_output_and_explain_renders() {
  local plan out
  reset_copy
  plan=$("$PLANNER" plan --event push) || fail "plan failed"
  : >"$TMP_ROOT/github-output"
  FM_CI_PLAN=$plan GITHUB_OUTPUT="$TMP_ROOT/github-output" "$PLANNER" gate macos >/dev/null || fail "gate failed"
  [ "$(cat "$TMP_ROOT/github-output")" = run=true ] || fail "gate must append its result to GITHUB_OUTPUT"
  out=$(FM_CI_PLAN=$plan "$PLANNER" explain) || fail "explain failed"
  assert_contains "$out" "CI plan: full" "explain must name the mode"
  assert_contains "$out" "event push" "explain must give the full-suite reason"
  pass "gate appends to GITHUB_OUTPUT and explain renders the plan"
}

test_single_test_change_runs_only_that_script_in_its_lane
test_unreferenced_document_runs_only_the_prose_check
test_bin_change_lints_its_partition_and_every_sourcer
test_full_triggers_give_their_reason
test_full_plan_runs_every_check_whole
test_gate_refuses_a_missing_malformed_or_stale_plan
test_gate_writes_github_output_and_explain_renders

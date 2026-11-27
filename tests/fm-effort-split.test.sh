#!/usr/bin/env bash
# Tests for bin/fm-effort-split.sh: one week's merged PRs across the registered
# projects, by the `Class:` line of each body (bin/fm-pr-class-lib.sh). A fake
# gh serves each repository's merged PRs from a file and logs its calls, so
# each case asserts the week it asked for, the classes and capped lines it
# counted, the verdict, and the projects it read or skipped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPLIT="$ROOT/bin/fm-effort-split.sh"
TMP_ROOT=$(fm_test_tmproot fm-effort-split-tests)

# new_case: a home registering alpha and beta (GitHub clones), gamma (no
# clone) and delta (a non-GitHub origin), plus a fake gh that serves
# <case>/prs-<repo>.json. Echoes the case directory.
new_case() {
  local c name
  c=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$c/home/data" "$c/home/config" "$c/home/projects" "$c/fakebin"
  printf '%s\n' '# Projects' \
    '- alpha [direct-PR +yolo] - First (added 2026-08-25)' \
    '- beta [direct-PR] - Second (added 2026-08-25)' \
    '- gamma [direct-PR] - Not cloned (added 2026-08-25)' \
    '- delta [direct-PR] - Elsewhere (added 2026-08-25)' \
    '- alpha-again [direct-PR] - Same origin as alpha (added 2026-08-25)' \
    > "$c/home/data/projects.md"
  for name in alpha beta delta alpha-again; do
    fm_git_init_commit "$c/home/projects/$name"
  done
  git -C "$c/home/projects/alpha" remote add origin https://github.com/acme/alpha.git
  git -C "$c/home/projects/alpha-again" remote add origin git@github.com:acme/alpha.git
  git -C "$c/home/projects/beta" remote add origin https://github.com/acme/beta.git
  git -C "$c/home/projects/delta" remote add origin https://gitlab.example/acme/delta.git
  printf '[]\n' > "$c/prs-alpha.json"
  printf '[]\n' > "$c/prs-beta.json"
  cat > "$c/fakebin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$c/gh.log'
[ "\$1 \$2" = "pr list" ] || exit 1
repo=
while [ "\$#" -gt 0 ]; do
  [ "\$1" != --repo ] || repo=\$2
  shift
done
[ ! -e '$c/gh-fail' ] || exit 1
cat "$c/prs-\${repo#acme/}.json"
STUB
  chmod +x "$c/fakebin/gh"
  printf '%s\n' "$c"
}

run_split() {  # <case> [args...]
  local c=$1
  shift
  FM_HOME="$c/home" PATH="$c/fakebin:$PATH" "$SPLIT" "$@"
}

# pr <url> <additions> <deletions> <body>: one PR object.
pr() {
  jq -n --arg url "$1" --argjson a "$2" --argjson d "$3" --arg body "$4" \
    '{url: $url, additions: $a, deletions: $d, body: $body}'
}

test_counts_by_class_with_capped_lines_and_names_the_week() {
  local c out json
  c=$(new_case)
  {
    pr https://github.com/acme/alpha/pull/1 10 5 $'## Summary\n\nClass: sales\n'
    pr https://github.com/acme/alpha/pull/2 9000 1000 $'**Class:** fleet\n'
    pr https://github.com/acme/alpha/pull/3 40 0 $'An older PR with no Class line.\n'
    pr https://github.com/acme/alpha/pull/4 1 1 $'Class: marketing\n'
  } | jq -s . > "$c/prs-alpha.json"
  {
    pr https://github.com/acme/beta/pull/7 100 100 $'Class: cost\r\n'
    pr https://github.com/acme/beta/pull/8 5 5 $'Class: sapna\n'
  } | jq -s . > "$c/prs-beta.json"
  json=$(run_split "$c" --week 2026-W47 --json) || fail "the reader failed: $json"
  [ "$(printf '%s' "$json" | jq -r '.start + " " + .end')" = "2026-11-16T00:00:00Z 2026-11-22T23:59:59Z" ] \
    || fail "wrong week bounds: $(printf '%s' "$json" | jq -c '{start, end}')"
  grep -qF -- '--search merged:2026-11-16T00:00:00Z..2026-11-22T23:59:59Z' "$c/gh.log" \
    || fail "gh was not asked for the week's merged PRs: $(cat "$c/gh.log")"
  [ "$(printf '%s' "$json" | jq -c '[.by_class.sales, .by_class.cost, .by_class.fleet, .by_class.sapna, .by_class.unclassified]')" \
    = '[{"count":1,"lines":15},{"count":1,"lines":200},{"count":1,"lines":2000},{"count":1,"lines":10},{"count":2,"lines":42}]' ] \
    || fail "wrong per-class counts or capped lines: $(printf '%s' "$json" | jq -c .by_class)"
  # Shares leave out the sapna PR: 5 PRs, 2,257 capped lines.
  [ "$(printf '%s' "$json" | jq -c '[.domain_prs, .shares.sales_cost, .shares.fleet, .verdict]')" \
    = '[5,{"count":40,"lines":10},{"count":20,"lines":89},"fleet within target"]' ] \
    || fail "wrong shares or verdict: $(printf '%s' "$json" | jq -c '[.domain_prs, .shares, .verdict]')"
  [ "$(printf '%s' "$json" | jq -c '[.projects, .skipped]')" \
    = '[["alpha","beta"],["gamma (no clone)","delta (not GitHub)"]]' ] \
    || fail "wrong projects read or skipped: $(printf '%s' "$json" | jq -c '[.projects, .skipped]')"
  [ "$(grep -c '^pr list' "$c/gh.log")" = 2 ] || fail "a shared origin was read twice: $(cat "$c/gh.log")"
  out=$(run_split "$c" --week 2026-W47) || fail "the reader failed: $out"
  [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "the Monday line is not one line: $out"
  case "$out" in
    "Effort split 2026-W47 (2026-11-16..2026-11-22 UTC; read alpha, beta; skipped gamma (no clone), delta (not GitHub); 6 merged PRs, 2 unclassified): sales+cost 40% of PRs, 10% of capped lines (target at least 35%); fleet 20% of PRs, 89% of capped lines (target at most 30%): fleet within target; by class sales 1, cost 1, run 0, time 0, fleet 1, sapna 1, personal 0, unclassified 2 (sapna not in the shares)") ;;
    *) fail "unexpected Monday line: $out" ;;
  esac
  pass "fm-effort-split counts each PR by its Class line and capped lines, leaves sapna out of the shares, and names what it read"
}

test_fleet_over_target_and_empty_weeks() {
  local c json
  c=$(new_case)
  {
    pr https://github.com/acme/alpha/pull/1 1 0 $'Class: fleet\n'
    pr https://github.com/acme/alpha/pull/2 1 0 $'Class: fleet\n'
    pr https://github.com/acme/alpha/pull/3 1 0 $'Class: sales\n'
  } | jq -s . > "$c/prs-alpha.json"
  json=$(run_split "$c" --json --week 2026-W48) || fail "the reader failed: $json"
  [ "$(printf '%s' "$json" | jq -r .verdict)" = "fleet over target" ] \
    || fail "two of three fleet PRs did not read over target: $json"
  pr https://github.com/acme/alpha/pull/1 1 0 'no class' | jq -s . > "$c/prs-alpha.json"
  json=$(run_split "$c" --json --week 2026-W48) || fail "the reader failed: $json"
  [ "$(printf '%s' "$json" | jq -r .verdict)" = "no classified PRs" ] \
    || fail "an all-unclassified week did not say so: $json"
  printf '[]\n' > "$c/prs-alpha.json"
  json=$(run_split "$c" --json --week 2026-W48) || fail "the reader failed: $json"
  [ "$(printf '%s' "$json" | jq -r .verdict)" = "no merged PRs" ] || fail "an empty week did not say so: $json"
  pass "fm-effort-split reads a fleet share over 30 percent as over target, and names empty and unclassified weeks"
}

test_default_week_is_the_last_full_one() {
  local c json want
  c=$(new_case)
  json=$(run_split "$c" --json) || fail "the reader failed: $json"
  want=$(jq -nr '(now | strftime("%Y-%m-%dT00:00:00Z") | fromdate) as $t
    | $t - ((($t | strftime("%u") | tonumber) - 1) + 7) * 86400 | strftime("%G-W%V")')
  [ "$(printf '%s' "$json" | jq -r .week)" = "$want" ] \
    || fail "the default week is not the last full one ($want): $(printf '%s' "$json" | jq -r .week)"
  pass "fm-effort-split reads the last full ISO week by default"
}

test_refuses_bad_weeks_failed_reads_and_the_search_cap() {
  local c rc out
  c=$(new_case)
  for bad in 2026-47 2026-W5 2025-W53; do
    set +e
    out=$(run_split "$c" --week "$bad" 2>&1)
    rc=$?
    set -e
    [ "$rc" = 2 ] || fail "--week $bad should be bad usage (exit 2), got $rc: $out"
  done
  touch "$c/gh-fail"
  set +e
  out=$(run_split "$c" --week 2026-W47 2>&1)
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "a failed gh read should exit 1, got $rc: $out"
  case "$out" in *"could not read the merged PRs of acme/alpha"*) ;; *) fail "the failed read was not named: $out" ;; esac
  rm -f "$c/gh-fail"
  jq -n '[range(1000) | {url: "https://github.com/acme/alpha/pull/\(.)", additions: 1, deletions: 0, body: ""}]' \
    > "$c/prs-alpha.json"
  set +e
  out=$(run_split "$c" --week 2026-W47 2>&1)
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "a week at gh's search cap should exit 1, got $rc: $out"
  case "$out" in *"search cap"*) ;; *) fail "the search cap was not named: $out" ;; esac
  pass "fm-effort-split refuses a malformed or nonexistent week, a failed read, and a week at gh's search cap"
}

test_counts_by_class_with_capped_lines_and_names_the_week
test_fleet_over_target_and_empty_weeks
test_default_week_is_the_last_full_one
test_refuses_bad_weeks_failed_reads_and_the_search_cap

#!/usr/bin/env bash
# tests/fm-audit-ids.test.sh - bin/fm-audit-ids.py, which keeps audit finding
# ids unique across audits.
#
# The guarantees under test:
#   - next prints one past the highest number any prior record holds, per
#     prefix, two digits at least, and <prefix>-01 for a new --prefix; a
#     prose record counts a whole-token id only for a prefix a decision record
#     or --prefix names.
#   - Two audits in sequence never share an id: each audit numbered from next
#     over every earlier audit passes check, including after two earlier
#     audits that both hold a7-01 (the a7 run that used to restart).
#   - check lists each id a prior record holds (a7-5 and a7-05 are one id) or
#     the record repeats, exits 1, and names the record that holds it; it
#     skips the audit's own directory, so a glob over every audit may include it.
#   - It reads a findings list (.jsonl with id) as well as decisions.json, and
#     refuses a missing record, a record of neither shape and an id of another
#     shape; a bad command line exits 2; it writes nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TOOL="$ROOT/bin/fm-audit-ids.py"
TMP_ROOT=$(fm_test_tmproot fm-audit-ids)

# decisions <path> <id>...: a decisions.json holding each id.
decisions() {
  local path=$1
  shift
  python3 -I -c 'import json, sys; json.dump({i: {"decision": "do"} for i in sys.argv[2:]}, open(sys.argv[1], "w"), indent=1)' \
    "$path" "$@"
}

# mint <prefix> <count> <prior>...: the next <count> ids of <prefix>, from next.
mint() {
  local prefix=$1 count=$2 first n
  shift 2
  first=$("$TOOL" next --prefix "$prefix" "$@" | grep "^$prefix-") || return 1
  n=$((10#${first##*-}))
  for ((i = 0; i < count; i++)); do printf '%s-%02d\n' "$prefix" $((n + i)); done
}

test_next_continues_each_prefix() {
  local dir="$TMP_ROOT/next" out
  mkdir -p "$dir/a" "$dir/b"
  decisions "$dir/a/decisions.json" a1-01 a1-38 a7-39 guidance-30
  printf '%s\n' 'Arjun picked a1-58 and a7-12, saw helm-4, fleet-5 and audit-1126-firstmate-4; xa1-90 and a1-91-followup are not ids.' \
    >"$dir/b/walk-answers.md"
  out=$("$TOOL" next "$dir/a" "$dir/b" 2>&1) || fail "next failed: $out"
  assert_equals $'a1-59\na7-40\nguidance-31' "$out" "next continues each decision-record prefix past every record, prose included"
  out=$("$TOOL" next --prefix cap --prefix a7 "$dir/a/decisions.json" 2>&1) || fail "next --prefix failed: $out"
  assert_equals $'a1-39\na7-40\ncap-01\nguidance-31' "$out" "a new --prefix starts at 01, and a file prior reads alone"
  out=$("$TOOL" next --prefix helm "$dir/b" 2>&1) || fail "next over prose failed: $out"
  assert_equals "helm-05" "$out" "a prose-only prior counts a named prefix"
  pass "audit-ids: next prints one past the highest number per prefix across every prior record"
}

test_two_audits_in_sequence_never_share_an_id() {
  local dir="$TMP_ROOT/sequence" out ids
  mkdir -p "$dir/deep-audit-1124" "$dir/deep-audit-1126" "$dir/deep-audit-1128" "$dir/deep-audit-1130"
  # The legacy pair: both earlier audits restarted the a7 run at 01.
  decisions "$dir/deep-audit-1124/decisions.json" a1-39 a1-40 a7-01 a7-02 a7-03
  decisions "$dir/deep-audit-1126/decisions.json" a1-59 a7-01 a7-02
  # Audit 1128 numbers from next over both; audit 1130 from next over all three.
  ids=$(mint a7 3 "$dir"/deep-audit-1124 "$dir"/deep-audit-1126; mint a1 2 "$dir"/deep-audit-1124 "$dir"/deep-audit-1126)
  assert_equals "a7-04 a7-05 a7-06 a1-60 a1-61" "$(printf '%s' "$ids" | tr '\n' ' ')" "the third audit's ids start past both earlier audits"
  # shellcheck disable=SC2086 # each id is one word
  decisions "$dir/deep-audit-1128/decisions.json" $ids
  out=$("$TOOL" check "$dir/deep-audit-1128/decisions.json" "$dir"/deep-audit-* 2>&1) \
    || fail "check refused ids next minted: $out"
  assert_contains "$out" "ok: 5 id(s)" "check passes the third audit: $out"
  assert_contains "$out" "none in 2 prior record(s)" "check skips the audit's own directory from the glob: $out"

  ids=$(mint a7 2 "$dir"/deep-audit-1124 "$dir"/deep-audit-1126 "$dir"/deep-audit-1128)
  # shellcheck disable=SC2086 # each id is one word
  printf '{"id": "%s", "title": "t"}\n' $ids >"$dir/deep-audit-1130/findings.jsonl"
  out=$("$TOOL" check "$dir/deep-audit-1130/findings.jsonl" "$dir"/deep-audit-* 2>&1) \
    || fail "check refused the fourth audit's findings list: $out"
  assert_contains "$out" "ok: 2 id(s)" "a findings list is read too: $out"
  python3 -I - "$dir" <<'EOF' || fail "two audits share an id"
import json, sys, pathlib
seen = {}
for audit in ("deep-audit-1128", "deep-audit-1130"):
    root = pathlib.Path(sys.argv[1], audit)
    ids = list(json.load(open(root / "decisions.json"))) if (root / "decisions.json").exists() else \
        [json.loads(line)["id"] for line in open(root / "findings.jsonl")]
    for fid in ids:
        assert fid not in seen, f"{fid} in {seen.get(fid)} and {audit}"
        seen[fid] = audit
assert all(fid not in {"a7-01", "a7-02", "a7-03", "a1-39", "a1-40", "a1-59"} for fid in seen)
EOF
  pass "audit-ids: audits numbered from next never share an id, after a restarted a7 run too"
}

test_check_lists_each_shared_or_repeated_id() {
  local dir="$TMP_ROOT/check" out code=0 before
  mkdir -p "$dir/prior" "$dir/now"
  decisions "$dir/prior/decisions.json" a7-05 a1-10
  printf '%s\n' 'walk: a7-07 picked; guidance-14 cited.' >"$dir/prior/walk-answers.md"
  printf '%s\n' '{"id": "a7-5"}' '{"id": "a7-07"}' '{"id": "a7-40"}' '{"id": "a7-040"}' '{"id": "a1-11"}' \
    >"$dir/now/findings.jsonl"
  before=$(cksum <"$dir/now/findings.jsonl")
  out=$("$TOOL" check "$dir/now/findings.jsonl" "$dir/prior" 2>&1) || code=$?
  expect_code 1 "$code" "a shared id"
  assert_contains "$out" "3 id(s) another audit or this record already uses" "check counts each problem: $out"
  assert_contains "$out" "a7-5 (a prior audit holds it: $dir/prior/decisions.json)" "a7-5 is a7-05: $out"
  assert_contains "$out" "a7-07 (a prior audit holds it: $dir/prior/walk-answers.md)" "a prose record holds a7-07: $out"
  assert_contains "$out" "a7-040 (listed twice, as a7-40 and a7-040)" "a repeated number is listed: $out"
  assert_not_contains "$out" "a1-11" "a free id is not listed: $out"
  assert_equals "$before" "$(cksum <"$dir/now/findings.jsonl")" "check writes nothing"
  pass "audit-ids: check lists each id a prior record holds or the record repeats, naming its holder"
}

test_refusals_and_usage() {
  local dir="$TMP_ROOT/refuse" out code
  mkdir -p "$dir"
  printf '%s\n' '["a1-01"]' >"$dir/list.json"
  code=0; out=$("$TOOL" check "$dir/list.json" 2>&1) || code=$?
  expect_code 1 "$code" "an audit record of neither shape"
  assert_contains "$out" "refused" "a record of neither shape is a refusal: $out"
  decisions "$dir/decisions.json" a1-01 summary
  code=0; out=$("$TOOL" check "$dir/decisions.json" 2>&1) || code=$?
  expect_code 1 "$code" "an id of another shape"
  assert_contains "$out" "not <prefix>-<number> id(s): summary" "the bad id is named: $out"
  code=0; out=$("$TOOL" next "$dir/missing" 2>&1) || code=$?
  expect_code 1 "$code" "a missing prior record"
  assert_contains "$out" "no such record or directory" "the missing record is named: $out"
  code=0; out=$("$TOOL" next 2>&1) || code=$?
  expect_code 2 "$code" "next with no prefix"
  code=0; out=$("$TOOL" next --prefix A7 "$dir/decisions.json" 2>&1) || code=$?
  expect_code 2 "$code" "an uppercase prefix"
  code=0; out=$("$TOOL" check 2>&1) || code=$?
  expect_code 2 "$code" "check with no record"
  code=0; out=$("$TOOL" stamp 2>&1) || code=$?
  expect_code 2 "$code" "an unknown command"
  assert_contains "$out" "usage:" "a bad command line prints the usage"
  out=$("$TOOL" next --help 2>&1) || fail "--help failed"
  assert_contains "$out" "Usage: fm-audit-ids.py next" "--help prints the usage"
  pass "audit-ids: bad records are refused with exit 1, and a bad command line exits 2"
}

fm_test_run \
  test_next_continues_each_prefix \
  test_two_audits_in_sequence_never_share_an_id \
  test_check_lists_each_shared_or_repeated_id \
  test_refusals_and_usage

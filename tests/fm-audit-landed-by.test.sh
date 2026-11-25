#!/usr/bin/env bash
# tests/fm-audit-landed-by.test.sh - bin/fm-audit-landed-by.py, which writes
# each landed audit id's PR URLs from a wrap-up ledger.md into decisions.json.
#
# The guarantees under test:
#   - A landed id gets landed_by with every PR URL in its evidence cell, in
#     order without repeats; a landed id with no PR URL gets an empty list;
#     a non-landed id gets none; no other field, key or byte of layout moves.
#   - A second run changes nothing, byte for byte.
#   - A landed_by on an id the ledger now lists as not landed is dropped; an
#     id the ledger does not list is left alone.
#   - A one-space, ASCII-escaped file with no final newline and a two-space,
#     raw UTF-8, newline-terminated file each keep their layout.
#   - An escaped pipe inside a ledger cell is not a column boundary.
#   - It refuses a ledger id decisions.json lacks, a ledger with no table or
#     two, a Status that names landed but is not exactly landed,
#     and a layout it cannot reproduce, each leaving the file untouched.
#   - --dry-run reports and writes nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TOOL="$ROOT/bin/fm-audit-landed-by.py"
TMP_ROOT=$(fm_test_tmproot fm-audit-landed-by)

# write_ledger <path> <rows...>: a wrap-up ledger with the real header shape.
write_ledger() {
  local path=$1 row
  shift
  {
    printf '# a ledger\n\nTotals: whatever\n\n'
    printf '| Batch | Id | Status | Where it landed / evidence | What remains | Finding |\n'
    printf '|---|---|---|---|---|---|\n'
    for row in "$@"; do printf '%s\n' "$row"; done
    printf '\nTrailing prose.\n'
  } >"$path"
}

# A one-space, ASCII-escaped file with no final newline, as the deep audit writes.
write_decisions() {
  printf '%s' '{
 "a1-01": {
  "decision": "do",
  "title": "caf\u00e9 one",
  "status": "closed"
 },
 "a1-02": {
  "decision": "do",
  "status": "closed"
 },
 "a1-03": {
  "decision": "do",
  "status": "open"
 },
 "a1-04": {
  "decision": "no",
  "status": "closed"
 }
}' >"$1"
}

LEDGER_ROWS=(
  '| - | a1-01 | landed | https://github.com/o/biz/pull/12, https://github.com/o/fleet/pull/7; again https://github.com/o/biz/pull/12 |  | one \| an escaped pipe |'
  '| b | a1-02 | landed | helm step done 2026-11-20 (decisions.json) |  | two |'
  '| b | a1-03 | open-ship | https://github.com/o/biz/pull/99 closed | a ship | three |'
)

test_writes_landed_by_and_is_idempotent() {
  local dir="$TMP_ROOT/basic" out before
  mkdir -p "$dir"
  write_ledger "$dir/ledger.md" "${LEDGER_ROWS[@]}"
  write_decisions "$dir/decisions.json"
  out=$("$TOOL" "$dir/ledger.md" "$dir/decisions.json" 2>&1) || fail "first run failed: $out"
  assert_contains "$out" "2 landed id(s), 1 with no PR URL" "summary counts: $out"
  assert_contains "$out" "changed" "first run reports a change: $out"
  before=$(cksum <"$dir/decisions.json")
  out=$("$TOOL" "$dir/ledger.md" "$dir/decisions.json" 2>&1) || fail "second run failed: $out"
  assert_contains "$out" "unchanged" "second run reports no change: $out"
  assert_equals "$before" "$(cksum <"$dir/decisions.json")" "a second run changes no byte"
  pass "landed-by: landed ids gain their PR URLs or an empty list, and a rerun is a no-op"
}

test_exact_bytes() {
  local dir="$TMP_ROOT/bytes"
  mkdir -p "$dir"
  write_ledger "$dir/ledger.md" "${LEDGER_ROWS[@]}"
  write_decisions "$dir/decisions.json"
  "$TOOL" "$dir/ledger.md" "$dir/decisions.json" >/dev/null 2>&1 || fail "run failed"
  printf '%s' '{
 "a1-01": {
  "decision": "do",
  "title": "caf\u00e9 one",
  "status": "closed",
  "landed_by": [
   "https://github.com/o/biz/pull/12",
   "https://github.com/o/fleet/pull/7"
  ]
 },
 "a1-02": {
  "decision": "do",
  "status": "closed",
  "landed_by": []
 },
 "a1-03": {
  "decision": "do",
  "status": "open"
 },
 "a1-04": {
  "decision": "no",
  "status": "closed"
 }
}' >"$dir/expected.json"
  cmp -s "$dir/expected.json" "$dir/decisions.json" \
    || fail "decisions.json differs from the expected bytes:"$'\n'"$(diff "$dir/expected.json" "$dir/decisions.json")"
  pass "landed-by: the written file matches the expected bytes, key order and escaping kept"
}

test_stale_landed_by_dropped_unlisted_kept() {
  local dir="$TMP_ROOT/stale" out
  mkdir -p "$dir"
  printf '%s\n' '{
  "a1-01": {
    "status": "closed",
    "landed_by": ["https://github.com/o/biz/pull/1"],
    "note": "kept"
  },
  "a1-09": {
    "status": "closed",
    "landed_by": []
  }
}' >"$dir/raw.json"
  # Normalize the fixture to the two-space json.dumps layout the tool can keep.
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "$dir/raw.json" >"$dir/decisions.json"
  write_ledger "$dir/ledger.md" '| - | a1-01 | open-helm | was https://github.com/o/biz/pull/1, reverted | helm | one |'
  out=$("$TOOL" "$dir/ledger.md" "$dir/decisions.json" 2>&1) || fail "run failed: $out"
  assert_contains "$out" "1 stale removed" "summary counts the stale removal: $out"
  printf '%s\n' '{
  "a1-01": {
    "status": "closed",
    "note": "kept"
  },
  "a1-09": {
    "status": "closed",
    "landed_by": []
  }
}' >"$dir/expected.json"
  cmp -s "$dir/expected.json" "$dir/decisions.json" \
    || fail "stale handling differs:"$'\n'"$(diff "$dir/expected.json" "$dir/decisions.json")"
  pass "landed-by: a no-longer-landed id loses landed_by, an unlisted id keeps it"
}

test_two_space_unicode_newline_layout_kept() {
  local dir="$TMP_ROOT/layout"
  mkdir -p "$dir"
  printf '{\n  "x-1": {\n    "title": "café"\n  }\n}\n' >"$dir/decisions.json"
  write_ledger "$dir/ledger.md" '| - | x-1 | landed | https://github.com/o/r/pull/3 |  | x |'
  "$TOOL" "$dir/ledger.md" "$dir/decisions.json" >/dev/null 2>&1 || fail "run failed"
  printf '{\n  "x-1": {\n    "title": "café",\n    "landed_by": [\n      "https://github.com/o/r/pull/3"\n    ]\n  }\n}\n' >"$dir/expected.json"
  cmp -s "$dir/expected.json" "$dir/decisions.json" \
    || fail "layout not kept:"$'\n'"$(diff "$dir/expected.json" "$dir/decisions.json")"
  pass "landed-by: a two-space, raw UTF-8, newline-terminated file keeps its layout"
}

# expect_refusal <label> <needle> <ledger> <decisions>: exit 1, message, no write.
expect_refusal() {
  local label=$1 needle=$2 ledger=$3 decisions=$4 before out code=0
  before=$(cksum <"$decisions")
  out=$("$TOOL" "$ledger" "$decisions" 2>&1) || code=$?
  expect_code 1 "$code" "$label"
  assert_contains "$out" "refused" "$label names a refusal"
  assert_contains "$out" "$needle" "$label explains itself"
  assert_equals "$before" "$(cksum <"$decisions")" "$label leaves decisions.json untouched"
}

test_refusals_leave_the_file_untouched() {
  local dir="$TMP_ROOT/refuse"
  mkdir -p "$dir"
  write_decisions "$dir/decisions.json"

  write_ledger "$dir/unknown.md" "${LEDGER_ROWS[@]}" '| - | zz-99 | landed | https://github.com/o/r/pull/1 |  | gone |'
  expect_refusal "an unknown ledger id" "zz-99" "$dir/unknown.md" "$dir/decisions.json"

  printf '# a ledger\n\nNo table here, only prose.\n- a1-01 landed\n' >"$dir/notable.md"
  expect_refusal "a ledger with no table" "no recognizable ledger table" "$dir/notable.md" "$dir/decisions.json"

  printf '| Id | Status |\n|---|---|\n| a1-01 | landed |\n' >"$dir/nowhere.md"
  expect_refusal "a table without the evidence column" "no recognizable ledger table" "$dir/nowhere.md" "$dir/decisions.json"

  write_ledger "$dir/dupe.md" "${LEDGER_ROWS[@]}" '| - | a1-01 | moot | none |  | again |'
  expect_refusal "a duplicate ledger id" "appears twice" "$dir/dupe.md" "$dir/decisions.json"

  write_ledger "$dir/two.md" "${LEDGER_ROWS[@]}"
  printf '## batch 2\n\n| Id | Status | Where it landed / evidence |\n|---|---|---|\n| a1-04 | landed | https://github.com/o/r/pull/2 |\n' >>"$dir/two.md"
  expect_refusal "a second ledger table" "a second ledger table" "$dir/two.md" "$dir/decisions.json"

  write_ledger "$dir/bold.md" '| - | a1-01 | **landed** | https://github.com/o/r/pull/5 |  | one |'
  expect_refusal "a decorated landed status" "not exactly 'landed'" "$dir/bold.md" "$dir/decisions.json"

  printf '{"a1-01":{"status":"closed"},"a1-02":{},"a1-03":{}}' >"$dir/compact.json"
  write_ledger "$dir/ok.md" "${LEDGER_ROWS[@]}"
  expect_refusal "a layout it cannot reproduce" "refusing to reformat" "$dir/ok.md" "$dir/compact.json"
  pass "landed-by: unknown ids, tableless or two-table ledgers, odd statuses and foreign layouts are refused untouched"
}

test_dry_run_writes_nothing() {
  local dir="$TMP_ROOT/dry" before out
  mkdir -p "$dir"
  write_ledger "$dir/ledger.md" "${LEDGER_ROWS[@]}"
  write_decisions "$dir/decisions.json"
  before=$(cksum <"$dir/decisions.json")
  out=$("$TOOL" --dry-run "$dir/ledger.md" "$dir/decisions.json" 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "would change" "dry run says what it would do: $out"
  assert_equals "$before" "$(cksum <"$dir/decisions.json")" "dry run writes nothing"
  pass "landed-by: --dry-run reports and writes nothing"
}

fm_test_run \
  test_writes_landed_by_and_is_idempotent \
  test_exact_bytes \
  test_stale_landed_by_dropped_unlisted_kept \
  test_two_space_unicode_newline_layout_kept \
  test_refusals_leave_the_file_untouched \
  test_dry_run_writes_nothing

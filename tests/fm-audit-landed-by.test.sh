#!/usr/bin/env bash
# tests/fm-audit-landed-by.test.sh - bin/fm-audit-landed-by.py, which stamps
# each audit id a merged PR names into decisions.json.
#
# A fake gh on PATH serves recorded fixtures (no live gh): `search prs` returns
# the fixture records merged inside the asked window, and `pr view` reads a
# URL's state from a fixture map.
#
# The guarantees under test:
#   - An approved id a merged PR names, in its title or body as a whole token,
#     gets status landed and every such PR's URL in landed_by; an id no PR
#     names, a declined id, a non-merged record and a near-miss token
#     (a1-030, xa1-03) stamp nothing; no other field, key or layout byte moves.
#   - A second run changes nothing, byte for byte.
#   - An open-ship id a PR names becomes landed, while an open-helm or
#     open-captain id keeps its status and only gains landed_by, so a
#     half-landing never reads done.
#   - An existing landed_by URL no PR names is kept when gh reads it MERGED and
#     dropped otherwise, and the id's status stays; nothing is un-stamped.
#   - An id an --also audit file also holds is never stamped; the summary
#     lists each one a PR named, with its PRs (the a7-05/a7-07 case).
#   - With ids bin/fm-audit-ids.py numbered unique across audits, a later
#     audit's PR stamps no earlier finding even without --also.
#   - --table writes the prior-status table from the stamped record, marking a
#     kept hand URL (hand), with one row per approved id.
#   - The search passes --merged and every --owner, and a window that fills
#     gh's cap is split until each part fits; a single full day is refused.
#   - It refuses a failed gh call, a layout it cannot reproduce and a landed_by
#     that is not a list of PR URLs, each leaving the file untouched.
#   - --dry-run reports and writes nothing; a bad command line exits 2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TOOL="$ROOT/bin/fm-audit-landed-by.py"
TMP_ROOT=$(fm_test_tmproot fm-audit-landed-by)
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"

# The fake gh. FAKE_GH_PRS: search fixture (records carry a `day` the fake
# filters on); FAKE_GH_STATES: url -> state map for `pr view`; FAKE_GH_LOG:
# one line per call; FAKE_GH_FULL=range makes any multi-day window fill the
# cap, =day makes every window fill it; FAKE_GH_FAIL=1 fails every call.
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env python3
import datetime as dt, json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if os.environ.get("FAKE_GH_FAIL"):
    sys.exit("fake gh: offline")
if args[:2] == ["search", "prs"]:
    since, until = (dt.date.fromisoformat(d) for d in args[args.index("--merged-at") + 1].split(".."))
    limit = int(args[args.index("--limit") + 1])
    full = os.environ.get("FAKE_GH_FULL", "")
    if full == "day" or (full == "range" and since != until):
        print(json.dumps([{"url": f"https://github.com/o/filler/pull/{n}", "title": "filler", "body": "",
                           "state": "merged"} for n in range(limit)]))
        sys.exit(0)
    prs = json.load(open(os.environ["FAKE_GH_PRS"]))
    print(json.dumps([p for p in prs if since <= dt.date.fromisoformat(p["day"]) <= until][:limit]))
elif args[:2] == ["pr", "view"]:
    states = json.load(open(os.environ["FAKE_GH_STATES"]))
    if args[2] not in states:
        sys.exit(f"fake gh: no pull request {args[2]}")
    print(json.dumps({"state": states[args[2]]}))
else:
    sys.exit("fake gh: unexpected call")
EOF
chmod +x "$FAKE_BIN/gh"

# write_prs <path>: merged PRs naming ids, plus records that must not stamp.
write_prs() {
  printf '%s\n' '[
 {"day": "2026-11-21", "state": "merged", "url": "https://github.com/o/biz/pull/12",
  "title": "fix: the thing (a1-01)", "body": "Also see a1-030, xa1-03 and a1-03-followup; declines a1-04; repo half of a1-08."},
 {"day": "2026-11-23", "state": "merged", "url": "https://github.com/o/fleet/pull/7",
  "title": "chore: tidy", "body": "## Summary\nAudit items a1-01, a1-05, a1-06 and a1-07, from the deep audit."},
 {"day": "2026-11-24", "state": "closed", "url": "https://github.com/o/biz/pull/30",
  "title": "a1-02 attempt", "body": "never merged"},
 {"day": "2026-11-25", "state": "merged", "url": "https://github.com/o/nova/pull/40",
  "title": "Nova: trim working files", "body": "no audit id here"}
]' >"$1"
}

# A one-space, ASCII-escaped file with no final newline, as the deep audit writes.
write_decisions() {
  printf '%s' '{
 "a1-01": {
  "decision": "do",
  "title": "café one | piped",
  "status": "open"
 },
 "a1-02": {
  "decision": "do",
  "title": "two",
  "status": "done-helm-2026-11-20",
  "landed_by": [
   "https://github.com/o/nova/pull/40",
   "https://github.com/o/biz/pull/899",
   "https://github.com/o/cade/pull/5"
  ]
 },
 "a1-03": {
  "decision": "do",
  "title": "three",
  "status": "open"
 },
 "a1-04": {
  "decision": "no",
  "title": "four",
  "status": "closed",
  "landed_by": [
   "https://github.com/o/gone/pull/1"
  ]
 },
 "a1-05": {
  "decision": "do",
  "title": "five",
  "status": "landed",
  "landed_by": [
   "https://github.com/o/fleet/pull/7"
  ]
 },
 "a1-06": {
  "decision": "do",
  "title": "six",
  "status": "open-ship"
 },
 "a1-07": {
  "decision": "do",
  "title": "seven",
  "status": "open-helm"
 },
 "a1-08": {
  "decision": "do",
  "title": "eight",
  "status": "open-captain"
 }
}' >"$1"
}

# run_tool <dir> <args...>: the tool with the fake gh and this dir's fixtures.
run_tool() {
  local dir=$1
  shift
  PATH="$FAKE_BIN:$PATH" FAKE_GH_PRS="$dir/prs.json" FAKE_GH_STATES="$dir/states.json" \
    FAKE_GH_LOG="$dir/gh.log" "$TOOL" "$@"
}

# setup <dir>: fixtures for one case.
setup() {
  mkdir -p "$1"
  write_prs "$1/prs.json"
  write_decisions "$1/decisions.json"
  # 899 never merged; cade/5 merged before the search window.
  printf '%s\n' '{"https://github.com/o/biz/pull/899": "OPEN", "https://github.com/o/cade/pull/5": "MERGED"}' >"$1/states.json"
  : >"$1/gh.log"
}

WINDOW=(--owner o --since 2026-11-20 --until 2026-11-27)

test_stamps_named_ids_and_is_idempotent() {
  local dir="$TMP_ROOT/basic" out before
  setup "$dir"
  out=$(run_tool "$dir" "${WINDOW[@]}" "$dir/decisions.json" 2>&1) || fail "first run failed: $out"
  assert_contains "$out" "3 merged PR(s) searched; 5 id(s) named by one, 2 newly landed, 2 held at open-helm/open-captain" "summary counts: $out"
  assert_contains "$out" "2 hand URL(s) kept, 1 unmerged URL(s) dropped; 0 id(s) another audit shares left for the helm; changed" "summary counts the hand URLs: $out"
  printf '%s' '{
 "a1-01": {
  "decision": "do",
  "title": "café one | piped",
  "status": "landed",
  "landed_by": [
   "https://github.com/o/biz/pull/12",
   "https://github.com/o/fleet/pull/7"
  ]
 },
 "a1-02": {
  "decision": "do",
  "title": "two",
  "status": "done-helm-2026-11-20",
  "landed_by": [
   "https://github.com/o/nova/pull/40",
   "https://github.com/o/cade/pull/5"
  ]
 },
 "a1-03": {
  "decision": "do",
  "title": "three",
  "status": "open"
 },
 "a1-04": {
  "decision": "no",
  "title": "four",
  "status": "closed",
  "landed_by": [
   "https://github.com/o/gone/pull/1"
  ]
 },
 "a1-05": {
  "decision": "do",
  "title": "five",
  "status": "landed",
  "landed_by": [
   "https://github.com/o/fleet/pull/7"
  ]
 },
 "a1-06": {
  "decision": "do",
  "title": "six",
  "status": "landed",
  "landed_by": [
   "https://github.com/o/fleet/pull/7"
  ]
 },
 "a1-07": {
  "decision": "do",
  "title": "seven",
  "status": "open-helm",
  "landed_by": [
   "https://github.com/o/fleet/pull/7"
  ]
 },
 "a1-08": {
  "decision": "do",
  "title": "eight",
  "status": "open-captain",
  "landed_by": [
   "https://github.com/o/biz/pull/12"
  ]
 }
}' >"$dir/expected.json"
  cmp -s "$dir/expected.json" "$dir/decisions.json" \
    || fail "decisions.json differs from the expected bytes:"$'\n'"$(diff "$dir/expected.json" "$dir/decisions.json")"
  before=$(cksum <"$dir/decisions.json")
  out=$(run_tool "$dir" "${WINDOW[@]}" "$dir/decisions.json" 2>&1) || fail "second run failed: $out"
  assert_contains "$out" "0 newly landed" "second run lands nothing new: $out"
  assert_contains "$out" "unchanged" "second run reports no change: $out"
  assert_equals "$before" "$(cksum <"$dir/decisions.json")" "a second run changes no byte"
  pass "landed-by: merged PRs that name an id stamp it landed (an open-helm or open-captain id keeps its status), hand URLs are checked, and a rerun is a no-op"
}

test_search_args_and_window_split() {
  local dir="$TMP_ROOT/split" out searches
  setup "$dir"
  out=$(PATH="$FAKE_BIN:$PATH" FAKE_GH_FULL=range FAKE_GH_PRS="$dir/prs.json" FAKE_GH_STATES="$dir/states.json" \
    FAKE_GH_LOG="$dir/gh.log" "$TOOL" --dry-run --owner o --owner p --since 2026-11-20 --until 2026-11-27 \
    "$dir/decisions.json" 2>&1) || fail "split run failed: $out"
  assert_contains "$out" "3 merged PR(s) searched; 5 id(s) named by one" "the split windows find every PR once: $out"
  assert_contains "$(head -1 "$dir/gh.log")" "search prs --merged --owner o --owner p --merged-at 2026-11-20..2026-11-27" \
    "the search asks for merged PRs of every owner"
  searches=$(grep -c '^search prs' "$dir/gh.log")
  assert_equals 15 "$searches" "an eight-day window that fills the cap splits down to single days"
  assert_contains "$(cat "$dir/gh.log")" "--merged-at 2026-11-27..2026-11-27" "the last day is searched on its own"

  : >"$dir/gh.log"
  local code=0 before
  before=$(cksum <"$dir/decisions.json")
  out=$(PATH="$FAKE_BIN:$PATH" FAKE_GH_FULL=day FAKE_GH_PRS="$dir/prs.json" FAKE_GH_STATES="$dir/states.json" \
    FAKE_GH_LOG="$dir/gh.log" "$TOOL" "${WINDOW[@]}" "$dir/decisions.json" 2>&1) || code=$?
  expect_code 1 "$code" "a full single day"
  assert_contains "$out" "one day fills gh's 1000-result search cap" "the refusal names the cap: $out"
  assert_equals "$before" "$(cksum <"$dir/decisions.json")" "a full single day leaves decisions.json untouched"
  pass "landed-by: the search names --merged and each owner, and a capped window splits until it fits"
}

test_prior_status_table() {
  local dir="$TMP_ROOT/table" out
  setup "$dir"
  out=$(run_tool "$dir" "${WINDOW[@]}" --table "$dir/prior.md" "$dir/decisions.json" 2>&1) || fail "run failed: $out"
  printf '%s\n' \
    '# Prior-status table' \
    '' \
    "Built by bin/fm-audit-landed-by.py from PRs by o merged 2026-11-20..2026-11-27 that name each id, and from decisions.json's status." \
    'A URL marked (hand) is merged, but no PR this search found names its id with it, as when someone entered it by hand.' \
    '' \
    '| Id | Status | Landed by | Title |' \
    '|---|---|---|---|' \
    '| a1-01 | landed | https://github.com/o/biz/pull/12, https://github.com/o/fleet/pull/7 | café one \| piped |' \
    '| a1-02 | done-helm-2026-11-20 | https://github.com/o/nova/pull/40 (hand), https://github.com/o/cade/pull/5 (hand) | two |' \
    '| a1-03 | open | - | three |' \
    '| a1-05 | landed | https://github.com/o/fleet/pull/7 | five |' \
    '| a1-06 | landed | https://github.com/o/fleet/pull/7 | six |' \
    '| a1-07 | open-helm | https://github.com/o/fleet/pull/7 | seven |' \
    '| a1-08 | open-captain | https://github.com/o/biz/pull/12 | eight |' >"$dir/expected.md"
  cmp -s "$dir/expected.md" "$dir/prior.md" \
    || fail "the table differs:"$'\n'"$(diff "$dir/expected.md" "$dir/prior.md")"
  pass "landed-by: --table writes one prior-status row per approved id from the stamped record"
}

# The 2026-11-24 case: a7-05 and a7-07 restarted in the next audit, whose PRs
# name its own a7-05 and a7-07. Without --also they stamp the earlier audit;
# with the later audit's decisions.json as --also they are left for the helm.
test_also_leaves_shared_ids_for_the_helm() {
  local dir="$TMP_ROOT/also" out before code=0
  mkdir -p "$dir"
  printf '%s\n' '[
 {"day": "2026-11-26", "state": "merged", "url": "https://github.com/o/firstmate/pull/313",
  "title": "feat(tasks-axi): responder-safe adds (audit a7-01, a7-05)", "body": ""},
 {"day": "2026-11-26", "state": "merged", "url": "https://github.com/o/firstmate/pull/315",
  "title": "feat(landing): covers lines (audit a7-07, a4-02)", "body": ""}
]' >"$dir/prs.json"
  printf '{}\n' >"$dir/states.json"
  : >"$dir/gh.log"
  printf '{\n  "a7-05": {\n    "status": "open"\n  },\n  "a7-07": {\n    "status": "open"\n  },\n  "a4-02": {\n    "status": "open"\n  }\n}\n' >"$dir/decisions.json"
  printf '{\n  "a7-01": {},\n  "a7-05": {},\n  "a7-07": {}\n}\n' >"$dir/later.json"
  cp "$dir/decisions.json" "$dir/fresh.json"

  out=$(run_tool "$dir" --dry-run "${WINDOW[@]}" "$dir/decisions.json" 2>&1) || fail "run without --also failed: $out"
  assert_contains "$out" "3 id(s) named by one, 3 newly landed" "without --also the later audit's PRs stamp every shared id: $out"

  out=$(run_tool "$dir" "${WINDOW[@]}" --also "$dir/later.json" "$dir/decisions.json" 2>&1) || fail "run with --also failed: $out"
  assert_contains "$out" "1 id(s) named by one, 1 newly landed" "only the unshared id is stamped: $out"
  assert_contains "$out" "2 id(s) another audit shares left for the helm, a7-05 (https://github.com/o/firstmate/pull/313), a7-07 (https://github.com/o/firstmate/pull/315); changed" \
    "the summary lists each shared id a PR named, with its PRs: $out"
  printf '{\n  "a7-05": {\n    "status": "open"\n  },\n  "a7-07": {\n    "status": "open"\n  },\n  "a4-02": {\n    "status": "landed",\n    "landed_by": [\n      "https://github.com/o/firstmate/pull/315"\n    ]\n  }\n}\n' >"$dir/expected.json"
  cmp -s "$dir/expected.json" "$dir/decisions.json" \
    || fail "--also result differs:"$'\n'"$(diff "$dir/expected.json" "$dir/decisions.json")"

  before=$(cksum <"$dir/fresh.json")
  out=$(run_tool "$dir" "${WINDOW[@]}" --also "$dir/missing.json" "$dir/fresh.json" 2>&1) || code=$?
  expect_code 1 "$code" "a missing --also file"
  assert_contains "$out" "refused" "a missing --also file is a refusal: $out"
  assert_equals "$before" "$(cksum <"$dir/fresh.json")" "a missing --also file leaves decisions.json untouched"
  pass "landed-by: an id an --also audit shares is never stamped and is listed for the helm"
}

# Unique ids: the later audit numbers its a7 run from bin/fm-audit-ids.py next
# over the earlier audit, so its PRs name ids the earlier decisions.json does
# not hold, and a run with no --also stamps none of the earlier findings.
test_unique_ids_need_no_also() {
  local dir="$TMP_ROOT/unique" out later
  mkdir -p "$dir/earlier"
  printf '{\n  "a7-05": {\n    "status": "open"\n  },\n  "a7-07": {\n    "status": "open"\n  }\n}\n' >"$dir/earlier/decisions.json"
  cp "$dir/earlier/decisions.json" "$dir/before.json"
  later=$("$ROOT/bin/fm-audit-ids.py" next "$dir/earlier") || fail "fm-audit-ids.py next failed"
  assert_equals "a7-08" "$later" "the later audit's a7 run starts past the earlier audit's"
  printf '[\n {"day": "2026-11-26", "state": "merged", "url": "https://github.com/o/firstmate/pull/313",\n  "title": "feat: responder-safe adds (audit %s)", "body": "Closes %s."}\n]\n' "$later" "$later" >"$dir/prs.json"
  printf '{}\n' >"$dir/states.json"
  : >"$dir/gh.log"
  out=$(run_tool "$dir" "${WINDOW[@]}" "$dir/earlier/decisions.json" 2>&1) || fail "run failed: $out"
  assert_contains "$out" "0 id(s) named by one, 0 newly landed" "the later audit's PR stamps no earlier finding: $out"
  cmp -s "$dir/before.json" "$dir/earlier/decisions.json" || fail "the earlier decisions.json changed"
  pass "landed-by: with ids unique across audits, a later audit's PR stamps no earlier finding without --also"
}

# expect_refusal <label> <needle> <dir> [env...] : exit 1, message, no write.
expect_refusal() {
  local label=$1 needle=$2 dir=$3 before out code=0
  shift 3
  before=$(cksum <"$dir/decisions.json")
  out=$(env "$@" PATH="$FAKE_BIN:$PATH" FAKE_GH_PRS="$dir/prs.json" FAKE_GH_STATES="$dir/states.json" \
    FAKE_GH_LOG="$dir/gh.log" "$TOOL" "${WINDOW[@]}" --table "$dir/prior.md" "$dir/decisions.json" 2>&1) || code=$?
  expect_code 1 "$code" "$label"
  assert_contains "$out" "refused" "$label names a refusal"
  assert_contains "$out" "$needle" "$label explains itself"
  assert_equals "$before" "$(cksum <"$dir/decisions.json")" "$label leaves decisions.json untouched"
  [ ! -e "$dir/prior.md" ] || fail "$label wrote a table"
}

test_refusals_leave_the_file_untouched() {
  local dir="$TMP_ROOT/refuse"
  setup "$dir"
  expect_refusal "a failing gh" "fake gh: offline" "$dir" FAKE_GH_FAIL=1

  printf '%s\n' '{}' >"$dir/states.json"
  expect_refusal "a hand URL gh cannot read" "no pull request https://github.com/o/biz/pull/899" "$dir"

  printf '{"a1-01":{"status":"open"},"a1-02":{}}' >"$dir/decisions.json"
  expect_refusal "a layout it cannot reproduce" "refusing to reformat" "$dir"

  printf '{\n  "a1-01": {\n    "landed_by": "https://github.com/o/biz/pull/12"\n  }\n}\n' >"$dir/decisions.json"
  expect_refusal "a landed_by that is not a list" "is not a list of PR URLs" "$dir"

  printf '{\n  "a1-01": {\n    "landed_by": [\n      "see the ledger"\n    ]\n  }\n}\n' >"$dir/decisions.json"
  expect_refusal "a landed_by that holds prose" "is not a list of PR URLs" "$dir"
  pass "landed-by: a failed gh call, an unreadable hand URL, a foreign layout and a bad landed_by are refused untouched"
}

test_dry_run_and_usage() {
  local dir="$TMP_ROOT/dry" before out code
  setup "$dir"
  before=$(cksum <"$dir/decisions.json")
  out=$(run_tool "$dir" --dry-run "${WINDOW[@]}" --table "$dir/prior.md" "$dir/decisions.json" 2>&1) \
    || fail "dry run failed: $out"
  assert_contains "$out" "would change" "dry run says what it would do: $out"
  assert_equals "$before" "$(cksum <"$dir/decisions.json")" "dry run writes nothing"
  [ ! -e "$dir/prior.md" ] || fail "dry run wrote a table"

  code=0; out=$(run_tool "$dir" --since 2026-11-20 "$dir/decisions.json" 2>&1) || code=$?
  expect_code 2 "$code" "no --owner"
  assert_contains "$out" "usage:" "a bad command line prints the usage"
  code=0; out=$(run_tool "$dir" --owner o "$dir/decisions.json" 2>&1) || code=$?
  expect_code 2 "$code" "no --since"
  code=0; out=$(run_tool "$dir" --owner o --since 2026-11-30 --until 2026-11-20 "$dir/decisions.json" 2>&1) || code=$?
  expect_code 2 "$code" "an inverted window"
  code=0; out=$(run_tool "$dir" --owner o --since yesterday "$dir/decisions.json" 2>&1) || code=$?
  expect_code 2 "$code" "a date that is not a date"
  out=$("$TOOL" --help 2>&1) || fail "--help failed"
  assert_contains "$out" "Usage: fm-audit-landed-by.py" "--help prints the usage"
  pass "landed-by: --dry-run writes nothing, and a bad command line exits 2"
}

fm_test_run \
  test_stamps_named_ids_and_is_idempotent \
  test_search_args_and_window_split \
  test_prior_status_table \
  test_also_leaves_shared_ids_for_the_helm \
  test_unique_ids_need_no_also \
  test_refusals_leave_the_file_untouched \
  test_dry_run_and_usage

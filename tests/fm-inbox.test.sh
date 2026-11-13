#!/usr/bin/env bash
# tests/fm-inbox.test.sh - captain inbox capture, receipts, replies, readiness.
#
# Covers the durable order contract: request-id idempotency, the crash window
# between save and announce, saved-but-unannounced repair, the unknown
# announced state of notes that predate the marker, bounded receipts JSON with
# omission disclosure, the reply cursor's strict order, and the readiness
# projection's model-aware verdict and unknown path. Human note/list/drain
# behaviour stays unchanged when the new flags are omitted.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LOCK_BIN="$ROOT/bin/fm-lock.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" "$@"
}

run_lock() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK_BIN" "$@"
}

json_get() {
  python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1:]:
    if isinstance(v, list) and k.lstrip("-").isdigit():
        v=v[int(k)]
    else:
        v=v[k]
print(v)' "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# --- human note path is unchanged without the new flags ---------------------

home=$(make_home human)
out=$(run_inbox "$home" note "hello from the terminal") \
  || fail "plain note should succeed"
assert_contains "$out" "queued " "plain note should print queued <id>"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "plain note should keep its human announcement line"
assert_equals "1" "$(count_notes "$home")" "plain note should write one record"
assert_equals "1" "$(count_wakes "$home")" "plain note should append one wake"
list_out=$(run_inbox "$home" list) || fail "list should succeed"
assert_contains "$list_out" "hello from the terminal" "list should show the body"
pass "plain note, list, and wake stay on the historical human path"

# A saved note whose wake fails still exits 1 for callers that omit the new flags.
isolated="$TMP_ROOT/isolated"
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
chmod +x "$isolated/bin/fm-inbox.sh"
home=$(make_home human-wake-fail)
set +e
fail_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note "saved but not announced" 2>&1)
fail_code=$?
set -e
expect_code 1 "$fail_code" "plain note still exits 1 when announcement fails"
assert_equals "1" "$(count_notes "$home")" \
  "plain note is saved even when announcement fails"
assert_contains "$fail_out" "queued " "plain note still prints queued before the failure"
assert_contains "$fail_out" "NOT woken" "plain note still reports the wake failure"
pass "plain note keeps exit 1 for a saved-but-unannounced failure"

# --- duplicate request id returns the original identity ---------------------

home=$(make_home idempotent)
body=$'line one\nline two\n'
first=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "first request-id note should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" \
  "first submission is created"
assert_equals "True" "$(printf '%s' "$first" | json_get saved)" \
  "first submission is saved"
assert_equals "True" "$(printf '%s' "$first" | json_get announced)" \
  "first submission is announced"
assert_equals "req-1" "$(printf '%s' "$first" | json_get request_id)" \
  "receipt carries the request id"

second=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "replay of the same request id should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "repeat request id is a replay, not a second create"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" \
  "the same request id must not create a second note"
assert_equals "1" "$(count_wakes "$home")" \
  "replay of an already-announced note must not append a second wake"
replay_human=$(run_inbox "$home" note --request-id req-1 "line one") \
  || fail "human replay should succeed"
assert_contains "$replay_human" "replay $first_id" \
  "human replay is distinguishable from queued"
assert_equals "1" "$(count_notes "$home")" "human replay still does not duplicate"
pass "the same request id returns the original note as a distinguishable replay"

# --- crash window: reservation exists, note not yet published ---------------

home=$(make_home crash-reserve)
mkdir -p "$home/state/inbox/.requests"
crash_id="1700000000-crashwin"
printf '%s\n' "$crash_id" > "$home/state/inbox/.requests/crash-rid"
assert_absent "$home/state/inbox/$crash_id.note" \
  "fixture starts with a reservation and no published note"
crash_out=$(run_inbox "$home" note --request-id crash-rid --json "recover me") \
  || fail "retry after a reservation-only crash should complete the original note"
assert_equals "replay" "$(printf '%s' "$crash_out" | json_get outcome)" \
  "completing a reserved request id is a replay of that request"
assert_equals "$crash_id" "$(printf '%s' "$crash_out" | json_get id)" \
  "the reserved note id is reused"
assert_present "$home/state/inbox/$crash_id.note" \
  "the retry publishes the reserved note rather than minting a new id"
assert_equals "1" "$(count_notes "$home")" \
  "crash-window retry leaves exactly one note"
assert_grep "recover me" "$home/state/inbox/$crash_id.note" \
  "the completed note carries the caller's body"
pass "a crash between recording the request id and publishing the note reuses the original id"

# --- saved-but-unannounced, then repair without a second note ---------------

home=$(make_home announce-fail)
set +e
saved_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
saved_code=$?
set -e
expect_code 3 "$saved_code" "request-id note exits 3 when saved but not announced"
assert_equals "created" "$(printf '%s' "$saved_out" | json_get outcome)" \
  "first isolated submit is created"
assert_equals "True" "$(printf '%s' "$saved_out" | json_get saved)" \
  "isolated submit saved the note"
assert_equals "False" "$(printf '%s' "$saved_out" | json_get announced)" \
  "isolated submit could not announce"
saved_id=$(printf '%s' "$saved_out" | json_get id)
assert_equals "1" "$(count_notes "$home")" "isolated submit wrote one note"
assert_equals "0" "$(count_wakes "$home")" "isolated submit wrote no wake"

set +e
replay_fail=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
replay_fail_code=$?
set -e
expect_code 3 "$replay_fail_code" "replay while still unannounced also exits 3"
assert_equals "replay" "$(printf '%s' "$replay_fail" | json_get outcome)" \
  "retry with the same request id is a replay"
assert_equals "$saved_id" "$(printf '%s' "$replay_fail" | json_get id)" \
  "unannounced retry keeps the original id"
assert_equals "1" "$(count_notes "$home")" \
  "unannounced retry must not create a second note"

repair=$(run_inbox "$home" note --request-id repair-1 --json "please announce") \
  || fail "replay with a working announcer should repair the wake"
assert_equals "replay" "$(printf '%s' "$repair" | json_get outcome)" \
  "repair is still a replay"
assert_equals "True" "$(printf '%s' "$repair" | json_get announced)" \
  "repair announces the existing note"
assert_equals "$saved_id" "$(printf '%s' "$repair" | json_get id)" \
  "repair keeps the original id"
assert_equals "1" "$(count_notes "$home")" "repair does not create a second note"
assert_equals "1" "$(count_wakes "$home")" "repair appends exactly one wake"

already=$(run_inbox "$home" announce --json "$saved_id") \
  || fail "announce of an already-announced note should succeed"
assert_equals "replay" "$(printf '%s' "$already" | json_get outcome)" \
  "second announce is already-announced"
assert_equals "1" "$(count_wakes "$home")" \
  "already-announced must not append another wake"
home=$(make_home announce-repair)
set +e
unannounced=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-2 --json "announce me" 2>/dev/null)
set -e
unannounced_id=$(printf '%s' "$unannounced" | json_get id)
assert_equals "0" "$(count_wakes "$home")" "the isolated submit wrote no wake"
repaired=$(run_inbox "$home" announce "$unannounced_id") \
  || fail "announce should repair a note this version saved but could not announce"
assert_contains "$repaired" "announced $unannounced_id" "the repair reports the announcement"
assert_equals "1" "$(count_wakes "$home")" "repairing appends exactly one wake"
pass "saved-but-unannounced notes are repairable without creating a second note"

# A note firstmate already acknowledged needs no wake, so neither the repair
# path nor a request-id replay appends one.
home=$(make_home announce-acked)
set +e
acked=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id acked-1 --json "drained before repair" 2>/dev/null)
set -e
acked_id=$(printf '%s' "$acked" | json_get id)
run_inbox "$home" drain --ack "$acked_id" >/dev/null || fail "drain --ack failed"
acked_repair=$(run_inbox "$home" announce --json "$acked_id") \
  || fail "announce of an acknowledged note should succeed without waking"
assert_equals "True" "$(printf '%s' "$acked_repair" | json_get acknowledged)" \
  "announce reports the note as already acknowledged"
assert_equals "False" "$(printf '%s' "$acked_repair" | json_get announced)" \
  "announce does not claim a wake it never appended"
acked_human=$(run_inbox "$home" announce "$acked_id") \
  || fail "human announce of an acknowledged note should succeed"
assert_contains "$acked_human" "already-acknowledged $acked_id" \
  "human announce names the acknowledgement"
acked_replay=$(run_inbox "$home" note --request-id acked-1 --json "drained before repair") \
  || fail "replay of an acknowledged note should exit 0"
assert_equals "replay" "$(printf '%s' "$acked_replay" | json_get outcome)" \
  "retry of an acknowledged note is a replay"
assert_equals "True" "$(printf '%s' "$acked_replay" | json_get acknowledged)" \
  "replay reports the note as already acknowledged"
assert_equals "0" "$(count_wakes "$home")" \
  "an acknowledged note never gets a repair wake"
pass "repair and replay do not wake firstmate for an already-acknowledged note"

# --- bounded receipts JSON, omission disclosure, reply cursor ---------------

json_len() {  # <key>
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

home=$(make_home receipts)
ids=""
i=0
while [ "$i" -lt 21 ]; do
  ids="$ids $(run_inbox "$home" note --request-id "bulk-$i" "bulk body $i" \
    | sed -n 's/^queued //p')"
  i=$((i + 1))
done

receipts=$(run_inbox "$home" receipts) || fail "receipts should succeed"
assert_equals "fm-inbox-receipts.v1" "$(printf '%s' "$receipts" | json_get schema)" \
  "receipts use the receipts schema"
assert_equals "20" "$(printf '%s' "$receipts" | json_len pending)" \
  "pending list is bounded without a reveal flag"
assert_contains "$receipts" "pending notes omitted by bound: 1" \
  "receipts disclose how many pending notes they omitted"
assert_contains "$receipts" "pass --all-pending" \
  "omission names the flag that reveals pending notes"
assert_contains "$receipts" '"acknowledged":false' "pending notes are not acknowledged"

all_receipts=$(run_inbox "$home" receipts --all-pending) \
  || fail "unbounded receipts should succeed"
assert_equals "21" "$(printf '%s' "$all_receipts" | json_len pending)" \
  "--all-pending reveals every pending note"
assert_equals "[]" "$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(json.load(sys.stdin)["omitted"])')" \
  "revealing every row leaves omitted empty"

# shellcheck disable=SC2086 # deliberate word splitting: one id per --ack arg.
run_inbox "$home" drain --ack $ids >/dev/null || fail "drain --ack of the bulk notes failed"
handled_receipts=$(run_inbox "$home" receipts) || fail "receipts after drain should succeed"
assert_equals "20" "$(printf '%s' "$handled_receipts" | json_len handled)" \
  "handled list is bounded without a reveal flag"
assert_contains "$handled_receipts" "handled notes omitted by bound: 1" \
  "receipts disclose how many handled notes they omitted"
assert_contains "$handled_receipts" "pass --all-handled" \
  "omission names the flag that reveals handled notes"
assert_equals "21" "$(run_inbox "$home" receipts --all-handled | json_len handled)" \
  "--all-handled reveals every handled note"
assert_contains "$handled_receipts" '"acknowledged":true' "handled notes are acknowledged"
pass "receipts JSON is bounded by fixed bounds and discloses what it omitted"

# A note written before this home tracked announcement markers already appended
# its own wake, and nothing proves that, so receipts say unknown rather than
# false and the repair path refuses it instead of appending a second wake.
home=$(make_home preexisting)
run_inbox "$home" note "establish the inbox" >/dev/null || fail "seed note failed"
legacy="1700000000-legacy"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\n--\nfrom before the marker\n' \
  "$legacy" > "$home/state/inbox/$legacy.note"
legacy_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
rows={r["id"]: r["announced"] for r in json.load(sys.stdin)["pending"]}
print(json.dumps(rows[sys.argv[1]]))' "$legacy")
assert_equals "null" "$legacy_announced" \
  "a note that predates the marker reports announced as unknown, not false"
fresh_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.dumps([r["announced"] for r in json.load(sys.stdin)["pending"] if r["id"] != sys.argv[1]]))' "$legacy")
assert_equals "[true]" "$fresh_announced" \
  "a note this version wrote still reports a definite announced state"
before_wakes=$(count_wakes "$home")
set +e
legacy_out=$(run_inbox "$home" announce "$legacy" 2>&1)
legacy_code=$?
set -e
expect_code 1 "$legacy_code" "announcing a note with an unknown announced state is refused"
assert_contains "$legacy_out" "UNKNOWN" "the refusal says the announced state is unknown"
assert_equals "$before_wakes" "$(count_wakes "$home")" \
  "the refused repair must not append a second wake"
pass "notes that predate the announcement marker are unknown, not re-announced"

# Reply cursor: replies recorded within the same second are both readable, in
# recording order, even when the later note id sorts below the earlier one.
home=$(make_home cursor)
mkdir -p "$home/state/inbox"
later="1700000000-aaaaaa"
earlier="1700000000-zzzzzz"
for nid in "$earlier" "$later"; do
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder %s\n' \
    "$nid" "$nid" > "$home/state/inbox/$nid.note"
done
run_inbox "$home" reply "$earlier" "answer one" >/dev/null || fail "first reply failed"
run_inbox "$home" reply "$later" "answer two" >/dev/null || fail "second reply failed"
replies=$(run_inbox "$home" receipts --all-replies) || fail "receipts with replies should succeed"
assert_equals "2" "$(printf '%s' "$replies" | json_len replies)" \
  "both replies appear without a cursor"
order=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(" ".join(r["id"] for r in json.load(sys.stdin)["replies"]))')
assert_equals "$earlier $later" "$order" "replies are ordered by when they were recorded"
first_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["replies"][0]["cursor"])')
after=$(run_inbox "$home" receipts --all-replies --after "$first_cursor") \
  || fail "receipts --after should succeed"
assert_equals "1" "$(printf '%s' "$after" | json_len replies)" \
  "--after returns only replies recorded later"
after_id=$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replies"][0]["id"])')
assert_equals "$later" "$after_id" \
  "a same-second reply recorded after the cursor is still delivered"

set +e
conflict=$(run_inbox "$home" reply "$earlier" "answer one" 2>&1)
conflict_code=$?
set -e
expect_code 1 "$conflict_code" "a second reply for the same note is refused"
assert_contains "$conflict" "already recorded" "the refusal names the existing record"
pass "the reply channel is durable and its cursor is a strict order"

# A lost sequence counter must not move the cursor backwards: the next reply
# still sorts after every reply a client has already read.
lost_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["reply_cursor"])')
rm -f "$home/state/inbox/.replies/.seq"
third="1700000000-mmmmmm"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder three\n' \
  "$third" > "$home/state/inbox/$third.note"
run_inbox "$home" reply "$third" "answer three" >/dev/null || fail "third reply failed"
after_lost=$(run_inbox "$home" receipts --after "$lost_cursor") \
  || fail "receipts after a lost counter should succeed"
assert_equals "$third" "$(printf '%s' "$after_lost" | json_get replies 0 id)" \
  "a reply recorded after the counter was lost is still after the client cursor"
pass "the reply cursor never goes backwards when the sequence counter is lost"

# A help flag is never recorded as the reply body, because a recorded reply
# cannot be replaced.
home=$(make_home reply-help)
mkdir -p "$home/state/inbox"
hid="1700000000-helpme"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\nq\n' \
  "$hid" > "$home/state/inbox/$hid.note"
for args in "--help" "-h" "$hid --help" "$hid -h" "--json $hid --help"; do
  set +e
  # shellcheck disable=SC2086
  help_out=$(run_inbox "$home" reply $args 2>&1)
  help_code=$?
  set -e
  expect_code 1 "$help_code" "reply $args exits as a usage request"
  assert_contains "$help_out" "usage: fm-inbox.sh reply" "reply $args prints the reply usage"
done
[ ! -e "$home/state/inbox/.replies/$hid" ] || fail "a help flag was recorded as the reply"
pass "reply prints usage for -h and --help and records nothing"

# A reply on a note with no request id is still recorded, but says that its
# sender has no handle to read it back; a note with one says nothing extra.
home=$(make_home reply-reader)
mkdir -p "$home/state/inbox"
printf 'id=1700000000-plainn\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\n[nova->arjun] allowlist a host\n' \
  > "$home/state/inbox/1700000000-plainn.note"
printf 'id=1700000000-reqidd\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\nrequest_id=handoff:nova-x-aa\n--\nfiled\n' \
  > "$home/state/inbox/1700000000-reqidd.note"
plain_out=$(run_inbox "$home" reply 1700000000-plainn "done") || fail "a reply on a plain note should be recorded"
assert_contains "$plain_out" "replied 1700000000-plainn" "the plain reply is recorded"
assert_contains "$plain_out" "no request id" "the plain reply says nothing can read it back"
mkdir -p "$home/state/inbox/handled"
mv "$home/state/inbox/1700000000-reqidd.note" "$home/state/inbox/handled/"
filed_out=$(run_inbox "$home" reply 1700000000-reqidd "done") || fail "a reply on an acknowledged filed note should be recorded"
assert_equals "replied 1700000000-reqidd" "$filed_out" "a reply its sender reads back prints only the record, after the ack too"
reply_count=$(run_inbox "$home" receipts --all-replies | python3 -c 'import json,sys
print(len(json.load(sys.stdin)["replies"]))')
assert_equals "2" "$reply_count" "both replies are recorded"
pass "a reply on a note with no request id says its sender cannot read it back"

# A reply without a valid sequence is malformed: it gets no invented position
# and receipts say so instead of silently ordering it.
home=$(make_home malformed-reply)
mkdir -p "$home/state/inbox/.replies"
bad="1700000000-badseq"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder\n' \
  "$bad" > "$home/state/inbox/$bad.note"
printf 'id=%s\nat=2026-01-01T00:00:00Z\n--\nno sequence here\n' \
  "$bad" >"$home/state/inbox/.replies/$bad"
malformed=$(run_inbox "$home" receipts) || fail "receipts with a malformed reply should succeed"
assert_equals "0" "$(printf '%s' "$malformed" | json_len replies)" \
  "a reply without a sequence is not placed in the reply stream"
assert_contains "$malformed" "malformed replies without a valid sequence: 1 ($bad)" \
  "receipts name the malformed reply"
pass "a reply without a valid sequence is reported as malformed"

# One undecodable note must not fail the whole receipts view.
home=$(make_home non-utf8)
run_inbox "$home" note "readable note" >/dev/null || fail "seed note failed"
printf 'id=1700000000-binary\nat=2026-01-01T00:00:00Z\nsource=text\n--\n\377\376 bytes\n' \
  > "$home/state/inbox/1700000000-binary.note"
binary=$(run_inbox "$home" receipts) || fail "receipts must survive a non-UTF-8 note"
assert_equals "2" "$(printf '%s' "$binary" | json_len pending)" \
  "the undecodable note and the readable note are both listed"
pass "a non-UTF-8 note does not break the receipts view"

# --- readiness projection, including unknown -------------------------------

home=$(make_home ready-free)
ready=$(run_inbox "$home" ready) || fail "ready should succeed with no lock"
assert_equals "fm-primary-ready.v1" "$(printf '%s' "$ready" | json_get schema)" \
  "ready uses the readiness schema"
assert_equals "free" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "no lock file is free, not live"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a free lock cannot receive work"
assert_equals "present" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["posture"]["state"])')" \
  "no away flag is present posture"

# A live non-harness pid in the lock file must not be treated as a live primary.
home=$(make_home ready-unknown)
printf '%s\n' "$$" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an unclassified pid"
lock_state=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')
assert_equals "unknown" "$lock_state" \
  "a live process that is not a verified harness is unknown, not held"
live=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["live_harness"])')
assert_equals "False" "$live" "a bash test pid is not a live harness"
can=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')
[ "$can" = "False" ] || [ "$can" = "unknown" ] \
  || fail "unknown lock must not claim can_receive true (got $can)"

human_lock=$(run_lock "$home" status) || fail "lock status should succeed"
assert_contains "$human_lock" "stale (pid $$ dead or not a harness)" \
  "human lock status keeps its historical stale wording"

# Dead pid is stale, not held.
home=$(make_home ready-stale)
printf '%s\n' "999999" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a dead pid"
assert_equals "stale" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a dead recorded pid is stale"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a stale lock cannot receive work"

# Existence of a pane-like leftover must not become liveness: unreadable lock.
home=$(make_home ready-unreadable)
mkdir -p "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a directory lock"
assert_equals "unreadable" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a non-file lock is unreadable rather than held"
# A Claude primary mid-turn runs no watcher process - its watcher is armed at
# turn end - so the model-aware supervision verdict, not the pid-strict watcher
# check, owns whether the wake will be drained.
home=$(make_home ready-midturn)
touch "$home/state/.last-watcher-beat"
midturn=$(FM_SUPERVISION_MODEL=autoarm run_inbox "$home" ready) \
  || fail "ready should succeed for a mid-turn autoarm primary"
assert_equals "healthy" "$(printf '%s' "$midturn" | json_get wake_consumer state)" \
  "a mid-turn autoarm primary with a fresh beacon has a healthy wake consumer"

# A home that never ran a watcher has no observation, so it reports no age
# rather than the missing-path sentinel. With no lock holder the model is
# unknown for this home, which is the honest caller path.
home=$(make_home ready-no-beacon)
nobeat=$(run_inbox "$home" ready) || fail "ready should succeed with no beacon"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$nobeat" | json_get wake_consumer reason)" \
  "no lock holder means the home's supervision model is unknown"
assert_equals "None" "$(printf '%s' "$nobeat" | json_get wake_consumer beacon_age_seconds)" \
  "a beacon that does not exist has no age"

# The intended caller (HTTP backend, ssh host fm-inbox.sh ready) does not set
# FM_SUPERVISION_MODEL. A live non-harness lock pid must not invent a model
# from the caller's own process tree.
home=$(make_home ready-no-override)
printf '%s\n' "$$" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
no_override=$(run_inbox "$home" ready) || fail "ready should succeed with no model override"
assert_equals "unknown" "$(printf '%s' "$no_override" | json_get wake_consumer state)" \
  "without a lock-holder harness, wake-consumer is unknown"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$no_override" | json_get wake_consumer reason)" \
  "the unknown reason names that the model could not be determined for this home"
can=$(printf '%s' "$no_override" | json_get can_receive)
assert_equals "unknown" "$can" "unknown lock plus unknown consumer is not can_receive true"

# A live lock holder whose ancestry names a known harness, plus a fresh
# beacon, is the yes path: the inspected home can receive work.
home=$(make_home ready-holder)
# A process whose ps comm is the harness name, so lock inspect and
# fm-harness.sh ancestry both classify it without PATH tricks.
perl -e '$0="claude"; sleep 60' &
holder_pid=$!
# Give ps a moment to report the renamed comm.
sleep 0.2
kill_holder() {
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}
trap 'kill_holder; fm_test_cleanup' EXIT
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
held=$(run_inbox "$home" ready) || fail "ready should succeed for a lock-holder harness"
assert_equals "held" "$(printf '%s' "$held" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a live claude-named holder is a held lock"
assert_equals "healthy" "$(printf '%s' "$held" | json_get wake_consumer state)" \
  "lock-holder ancestry plus a fresh beacon is a healthy wake consumer"
assert_equals "True" "$(printf '%s' "$held" | json_get can_receive)" \
  "a held lock with a healthy wake consumer can receive work"
kill_holder
trap fm_test_cleanup EXIT
pass "readiness says unknown (or not-receivable) instead of inferring liveness from a lock"

# --- invalid input ----------------------------------------------------------

home=$(make_home invalid)
set +e
empty_out=$(run_inbox "$home" note --request-id x --json "   " 2>&1)
empty_code=$?
bad_out=$(run_inbox "$home" note --request-id '../etc/passwd' --json "nope" 2>&1)
bad_code=$?
# An empty request id must be refused, never treated as "no request id given":
# falling through to the non-idempotent path would make a retry a second note.
blank_out=$(run_inbox "$home" note --request-id '' --json "silently duplicated" 2>&1)
blank_code=$?
set -e
expect_code 1 "$empty_code" "empty body is still refused"
expect_code 1 "$bad_code" "path-like request ids are refused"
expect_code 1 "$blank_code" "an empty request id is refused, not ignored"
assert_contains "$empty_out" "empty" "empty-body refusal says the note was empty"
assert_contains "$bad_out" "invalid request id" "unsafe request ids are rejected by name"
assert_contains "$blank_out" "invalid request id" "an empty request id is rejected by name"
assert_equals "0" "$(count_notes "$home")" "refusals must not write a note"
pass "empty bodies and unsafe request ids are refused"

# The voice handover passes a raw transcript as the first argument, so a body
# that opens with a double dash is text, not an option.
home=$(make_home dash-body)
transcript="--- handover: ship the console backend --now"
dash_out=$(run_inbox "$home" note "$transcript") \
  || fail "a note body opening with dashes should be queued"
assert_contains "$dash_out" "queued " "a dash-leading body is queued like any other"
assert_equals "1" "$(count_notes "$home")" "a dash-leading body writes one note"
dash_body=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.load(sys.stdin)["pending"][0]["body"])')
assert_equals "$transcript" "$dash_body" "the transcript is stored verbatim"
escaped=$(run_inbox "$home" note -- "--request-id is body text here") \
  || fail "-- should end option parsing"
assert_contains "$escaped" "queued " "-- escapes a body that looks like a flag"
pass "a note body that opens with a double dash is queued as text"

# --- drain still acks by moving the note ------------------------------------

home=$(make_home drain)
queued=$(run_inbox "$home" note "ack me") || fail "note for drain failed"
did=${queued#queued }
did=${did%%$'\n'*}
run_inbox "$home" drain --ack "$did" >/dev/null || fail "drain --ack failed"
assert_absent "$home/state/inbox/$did.note" "acked note leaves pending"
assert_present "$home/state/inbox/handled/$did.note" "acked note is in handled"
pass "drain --ack still moves the note to handled"

# --- unread lists pending notes oldest first, capped at ten -----------------

note_id() {  # <note-output>
  local id=${1#queued }
  printf '%s\n' "${id%%$'\n'*}"
}

home=$(make_home unread)
assert_equals "(no unread inbox notes)" "$(run_inbox "$home" unread)" \
  "an empty inbox reports no unread notes"
first=$(note_id "$(run_inbox "$home" note "the oldest note")")
sleep 1
second=$(note_id "$(run_inbox "$home" note "the newer note")")
unread_out=$(run_inbox "$home" unread) || fail "unread should succeed"
assert_contains "$unread_out" "2 unread inbox note(s), oldest first" "unread counts pending notes"
order=$(printf '%s\n' "$unread_out" | grep -Eo "$first|$second" | paste -sd' ' -)
assert_equals "$first $second" "$order" "unread lists the oldest note first"
assert_contains "$unread_out" "the oldest note" "unread shows each note's summary"
run_inbox "$home" drain --ack "$first" >/dev/null || fail "drain --ack failed"
unread_out=$(run_inbox "$home" unread)
assert_not_contains "$unread_out" "$first" "an acknowledged note leaves the unread list"
assert_contains "$unread_out" "1 unread inbox note(s)" "the count drops after an acknowledgement"
pass "unread lists pending notes oldest first and drops acknowledged ones"

home=$(make_home unread-cap)
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  run_inbox "$home" note "capped note $n" >/dev/null || fail "note $n failed"
done
unread_out=$(run_inbox "$home" unread)
assert_contains "$unread_out" "12 unread inbox note(s)" "the header counts every pending note"
assert_equals "10" "$(printf '%s\n' "$unread_out" | grep -c 'capped note')" \
  "unread shows at most ten notes"
assert_contains "$unread_out" "... and 2 more" "unread names how many it left out"
unread_json=$(run_inbox "$home" unread --json) || fail "unread --json should succeed"
assert_equals "12" "$(printf '%s' "$unread_json" | json_get total)" "JSON total counts every note"
assert_equals "10" "$(printf '%s' "$unread_json" | python3 -c 'import json,sys
print(len(json.load(sys.stdin)["notes"]))')" "JSON lists at most ten notes"
assert_equals "2" "$(printf '%s' "$unread_json" | json_get more)" "JSON names how many it left out"
pass "unread caps the list at ten with a count of the rest"

# --- rewake-due re-wakes an unacknowledged note once a day ------------------

# Drain and acknowledge every queued wake, as a firstmate turn that saw the
# note's wake but never acknowledged the note itself would.
drain_wakes() {  # <home>
  local err="$TMP_ROOT/drain.err"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" \
    || fail "wake drain failed: $(cat "$err")"
  ack_drain_err "$1/state" "$err" >/dev/null 2>&1 || fail "wake drain acknowledgement failed"
}

rewake() {  # <home> <seconds-from-now>
  FM_INBOX_NOW=$(( $(date +%s) + $2 )) run_inbox "$1" rewake-due
}

home=$(make_home rewake)
rid=$(note_id "$(run_inbox "$home" note "please look at this")")
assert_equals "" "$(rewake "$home" 86400)" "a note whose first wake is still queued is not re-woken"
drain_wakes "$home"
assert_equals "" "$(rewake "$home" 3600)" "a note an hour old is not re-woken"
assert_equals "rewoke $rid" "$(rewake "$home" 86400)" "a note 24 hours old is re-woken"
assert_contains "$(cat "$home/state/.wake-queue")" "captain inbox note $rid still unacknowledged after 24h" \
  "the re-wake queues a check wake naming the note"
drain_wakes "$home"
assert_equals "" "$(rewake "$home" 90000)" "a re-woken note waits another full day"
assert_equals "rewoke $rid" "$(rewake "$home" $((86400 * 2)))" "the note is re-woken again a day later"
drain_wakes "$home"
run_inbox "$home" drain --ack "$rid" >/dev/null || fail "drain --ack failed"
assert_equals "" "$(rewake "$home" $((86400 * 5)))" "an acknowledged note is never re-woken"
assert_equals "(no unread inbox notes)" "$(run_inbox "$home" unread)" \
  "an acknowledged note leaves the unread list"
pass "rewake-due re-wakes an unacknowledged note once a day until it is acknowledged"

# --- note --acknowledged saves a record that wakes nobody ------------------------

home=$(make_home acknowledged)
out=$(run_inbox "$home" note --acknowledged --request-id report:relay-1 --json "[cade] report relay-1: told Arjun") \
  || fail "note --acknowledged should succeed"
aid=$(printf '%s' "$out" | json_get id)
assert_equals "True" "$(printf '%s' "$out" | json_get acknowledged)" "an acknowledged note reports acknowledged"
assert_equals "False" "$(printf '%s' "$out" | json_get announced)" "an acknowledged note is not announced"
assert_equals "0" "$(count_notes "$home")" "an acknowledged note is not pending"
[ -f "$home/state/inbox/handled/$aid.note" ] || fail "an acknowledged note is saved under handled/"
assert_equals "0" "$(count_wakes "$home")" "an acknowledged note appends no wake"
out=$(run_inbox "$home" note --acknowledged --request-id report:relay-1 --json "[cade] report relay-1: told Arjun")
assert_equals "replay" "$(printf '%s' "$out" | json_get outcome)" "a repeat of the request id replays"
assert_equals "0" "$(count_wakes "$home")" "the replay appends no wake either"
pass "note --acknowledged saves straight into handled/ with no wake, idempotently"

# --- close-reply answers a handoff note only when nobody did ---------------------

home=$(make_home close-reply)
assert_equals "" "$(run_inbox "$home" close-reply hf-none "done" --pr https://github.com/o/r/pull/1)" \
  "a row no handoff filed is a silent no-op"
hid=$(run_inbox "$home" note --request-id handoff:hf-1 --json "[codex] handoff hf-1: fix it" | json_get id)
assert_equals "replied $hid (handoff hf-1 removed)" \
  "$(run_inbox "$home" close-reply hf-1 removed --reason "out of scope")" "close-reply records the reply"
body=$(run_inbox "$home" receipts --all-replies | json_get replies 0 body)
assert_contains "$body" "Reason: out of scope" "the removed reply carries the reason"
assert_equals "already-replied $hid (handoff hf-1)" "$(run_inbox "$home" close-reply hf-1 "done")" \
  "a second close leaves the first reply alone"
pass "close-reply answers a handoff note once and ignores rows without one"

# --- unread lists acknowledged handoffs closed with no reply ---------------------

home=$(make_home unreplied)
old=$(run_inbox "$home" note --request-id handoff:hf-gone --json "[claude] handoff hf-gone: the forgotten one" | json_get id)
answered=$(run_inbox "$home" note --request-id handoff:hf-answered --json "[claude] handoff hf-answered" | json_get id)
plain=$(run_inbox "$home" note --json "plain note, no handoff" | json_get id)
run_inbox "$home" drain --ack "$old" "$answered" "$plain" >/dev/null
run_inbox "$home" reply "$answered" "done" >/dev/null
assert_not_contains "$(run_inbox "$home" unread)" "$old" "a handoff acknowledged under a day ago is not listed yet"
later=$(( $(date +%s) + 90000 ))
out=$(FM_INBOX_NOW=$later run_inbox "$home" unread)
assert_contains "$out" "1 acknowledged handoff note(s) with no reply and no open backlog row" "unread counts the unanswered handoff"
assert_contains "$out" "$old" "unread names the unanswered handoff's note"
assert_contains "$out" "handoff hf-gone" "unread names the handoff's backlog item"
assert_not_contains "$out" "$answered" "an answered handoff is not listed"
assert_not_contains "$out" "$plain" "a note that is not a handoff is not listed"
json=$(FM_INBOX_NOW=$later run_inbox "$home" unread --json)
assert_equals "hf-gone" "$(printf '%s' "$json" | json_get unreplied_handoffs 0 item)" \
  "unread --json lists the unanswered handoff"
mkdir -p "$home/state/inbox/.handed-off" && printf 'sm-1\n' >"$home/state/inbox/.handed-off/hf-gone"
assert_not_contains "$(FM_INBOX_NOW=$later run_inbox "$home" unread)" "$old" \
  "a handoff moved to a secondmate closes there and is not listed"
rm -f "$home/state/inbox/.handed-off/hf-gone"
if command -v tasks-axi >/dev/null 2>&1; then
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' >"$home/data/backlog.md"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add hf-gone "Still queued" --kind task >/dev/null \
    || fail "could not add the open row"
  assert_not_contains "$(FM_INBOX_NOW=$later run_inbox "$home" unread)" "$old" \
    "a handoff whose row is still open waits for its close reply"
fi
pass "unread lists acknowledged handoff notes a day old with no reply and no open row"

# --- close-handed-off answers a moved row from the secondmate's terminal line ----

# A row fm-backlog-handoff.sh moved to secondmate sm-1, with its handoff note.
hand_off() {  # <home> <item> -> note id
  local id
  id=$(run_inbox "$1" note --request-id "handoff:$2" --json "[claude] handoff $2: do it" | json_get id)
  run_inbox "$1" drain --ack "$id" >/dev/null
  mkdir -p "$1/state/inbox/.handed-off"
  printf 'sm-1\n' >"$1/state/inbox/.handed-off/$2"
  printf '%s\n' "$id"
}

reply_count() {
  find "$1/state/inbox/.replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

home=$(make_home handed-off-pr)
nid=$(hand_off "$home" hf-1)
lone=$(hand_off "$home" hf-10)
printf '%s\n' \
  "working [at=1794600000]: dispatched hf-1" \
  "done [key=child-outcome-hf-1-done-0a1b2c3d] [at=1794600100]: child hf-1 done: PR https://github.com/o/r/pull/7 checks green pr=https://github.com/o/r/pull/7 mode=direct-PR yolo=on" \
  "done [key=child-outcome-hf-1-done-1b2c3d4e] [at=1794600110]: child hf-1 done: handed to validation mode=no-mistakes yolo=on" \
  "done [key=inactive-outcome-2c3d4e5f] [at=1794600120]: inactive terminal child=hf-1 fingerprint=abc" \
  >"$home/state/sm-1.status"
assert_equals "" "$(run_inbox "$home" close-handed-off)" "a ship child's done, with or without a PR, waits for its merge"
assert_equals "0" "$(reply_count "$home")" "no reply is written before the PR merges"
printf '%s\n' "done [key=merged-hf-1] [at=1794600200]: merged hf-1 https://github.com/o/r/pull/7 yolo" \
  "done [key=child-outcome-hf-1-done-3d4e5f6a] [at=1794600210]: child hf-1 done: PR https://github.com/o/r/pull/7 checks green pr=https://github.com/o/r/pull/7 mode=direct-PR" \
  >>"$home/state/sm-1.status"
assert_equals "replied $nid (handoff hf-1 done)" "$(run_inbox "$home" close-handed-off)" \
  "the merged line answers the handoff as done, even before a later ship done line"
body=$(run_inbox "$home" receipts --all-replies | json_get replies 0 body)
assert_contains "$body" "Done: firstmate closed backlog item hf-1" "the reply says the item is done"
assert_contains "$body" "PR: https://github.com/o/r/pull/7" "the reply carries the merged PR"
assert_contains "$body" "secondmate sm-1 reported it done" "the reply names the secondmate"
[ ! -e "$home/state/inbox/.handed-off/hf-1" ] || fail "an answered handoff keeps its handed-off marker"
[ -e "$home/state/inbox/.handed-off/hf-10" ] || fail "an item whose id only starts like the answered one lost its marker"
[ ! -e "$home/state/inbox/.replies/$lone" ] || fail "an item whose id only starts like the answered one got a reply"
pass "close-handed-off answers a moved row's handoff once its PR merges"

home=$(make_home handed-off-failed)
fid=$(hand_off "$home" hf-2)
sid=$(hand_off "$home" hf-3)
iid=$(hand_off "$home" hf-4)
cid=$(hand_off "$home" hf-7)
printf '%s\n' \
  "failed [key=child-outcome-hf-2-failed-1a2b3c4d] [at=1794600100]: child hf-2 failed: the API refused the token mode=direct-PR" \
  "done [key=hf-3] [at=1794600150]: scouted; nothing to change" \
  "done [key=child-outcome-hf-7-done-4e5f6a7b] [at=1794600155]: child hf-7 done: findings ready report=data/hf-7/report.md" \
  "failed [key=inactive-outcome-9f8e7d6c] [at=1794600160]: inactive terminal child=hf-4 fingerprint=abc" \
  >"$home/state/sm-1.status"
out=$(run_inbox "$home" close-handed-off)
assert_contains "$out" "replied $fid (handoff hf-2 removed)" "a failed child line answers as removed"
assert_contains "$out" "replied $sid (handoff hf-3 done)" "the mate's own done line keyed by the item answers as done"
assert_contains "$out" "replied $iid (handoff hf-4 removed)" "a failed inactive-outcome line answers as removed"
assert_contains "$out" "replied $cid (handoff hf-7 done)" "a scout child's done line answers as done"
receipts=$(run_inbox "$home" receipts --all-replies)
assert_contains "$receipts" "Reason: secondmate sm-1 reported it failed: the API refused the token" \
  "the removed reply carries the failure note without the scripted fields"
assert_not_contains "$receipts" "mode=direct-PR" "the scripted fields stay out of the reply"
assert_contains "$receipts" "Note: secondmate sm-1 reported it done: scouted; nothing to change" \
  "the done reply carries the mate's note"
assert_contains "$receipts" "Reason: secondmate sm-1 reported it failed: its task ended without a final status line" \
  "the inactive failure says why it carries no note"
assert_contains "$receipts" "Report: data/hf-7/report.md (as secondmate sm-1 reported it)" \
  "the scout's done reply carries its report, named as the mate's"
pass "close-handed-off answers failed and keyed done lines"

home=$(make_home handed-off-duplicate)
did=$(hand_off "$home" hf-5)
merged="done [key=merged-hf-5] [at=1794600200]: merged hf-5 https://github.com/o/r/pull/9"
printf '%s\n' "$merged" "$merged" >"$home/state/sm-1.status"
assert_equals "replied $did (handoff hf-5 done)" "$(run_inbox "$home" close-handed-off)" \
  "duplicate mirrored lines write one reply"
printf '%s\n' "$merged" >>"$home/state/sm-1.status"
printf 'sm-1\n' >"$home/state/inbox/.handed-off/hf-5"
assert_equals "" "$(run_inbox "$home" close-handed-off)" "a re-read after the reply writes nothing"
[ ! -e "$home/state/inbox/.handed-off/hf-5" ] || fail "a re-read leaves the answered marker behind"
assert_equals "1" "$(reply_count "$home")" "the note keeps exactly one reply"
pass "close-handed-off answers a handoff once across duplicate lines and re-reads"

home=$(make_home handed-off-boundaries)
printf '%s\n' "failed [key=child-outcome-hf-8-failed-5f6a7b8c] [at=1794500000]: child hf-8 failed: an earlier run" \
  >"$home/state/sm-1.status"
eid=$(hand_off "$home" hf-8)
printf 'sm-1\n%s\n' "$(wc -c <"$home/state/sm-1.status" | tr -d ' ')" >"$home/state/inbox/.handed-off/hf-8"
kid=$(hand_off "$home" hf-9)
printf 'sm-1\n%s\n' "$(wc -c <"$home/state/sm-1.status" | tr -d ' ')" >"$home/state/inbox/.handed-off/hf-9"
printf '%s\n' "done [key=hf-9] [at=1794600100]: PR ready https://github.com/o/r/pull/12" >>"$home/state/sm-1.status"
printf '%s' "done [key=merged-hf-8] [at=1794600200]: merged hf-8 https://github.com/o/r/pull/1" >>"$home/state/sm-1.status"
assert_equals "" "$(run_inbox "$home" close-handed-off)" \
  "a line from before the move, a keyed ready report, and an unfinished line answer nothing"
printf '3\n' >>"$home/state/sm-1.status"
assert_equals "replied $eid (handoff hf-8 done)" "$(run_inbox "$home" close-handed-off)" \
  "the merged line answers once it is complete"
assert_contains "$(run_inbox "$home" receipts --all-replies)" "PR: https://github.com/o/r/pull/13" \
  "the reply carries the complete PR link"
[ -e "$home/state/inbox/.handed-off/hf-9" ] || fail "a keyed ready report answered the handoff ($kid)"
pass "close-handed-off reads only complete lines written after the move, and not a keyed ready report"

home=$(make_home handed-off-no-note)
mkdir -p "$home/state/inbox/.handed-off"
printf 'sm-1\n' >"$home/state/inbox/.handed-off/hf-6"
printf '%s\n' "done [key=merged-hf-6] [at=1794600200]: merged hf-6 https://github.com/o/r/pull/11" \
  >"$home/state/sm-1.status"
assert_equals "" "$(run_inbox "$home" close-handed-off)" "a moved row with no handoff note is a silent no-op"
assert_equals "0" "$(reply_count "$home")" "a moved row with no handoff note gets no reply"
home=$(make_home handed-off-none)
assert_equals "" "$(run_inbox "$home" close-handed-off)" "a home with nothing handed off is a silent no-op"
pass "close-handed-off ignores a moved row with no handoff note"

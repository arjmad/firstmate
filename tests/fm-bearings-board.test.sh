#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A lavish-axi stub that reproduces the shapes verified against the real
# lavish-axi 0.1.61, because the build's liveness verdict is read from what the
# vendor emits. The load-bearing shape is the refusal: opening a session the
# captain ended from the browser EXITS 0 while reporting `status: user-ended`,
# and that session is absent from the server's listing. `--reopen` restores it.
# Markers under lavish-state drive the fixture: `user-ended` makes the next
# plain open refuse, and `refuse-reopen` makes even --reopen leave it dead.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # Registered with tests/lib.sh, not with a shell array: make_home is called
  # inside a command substitution, so an array append here never reaches the
  # caller and every listener this suite started used to survive the run.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
emit() {  # <canonical-file> <status>
  printf 'session:\n'
  printf '  file: %s\n' "$1"
  printf '  url: "http://127.0.0.1:4387/session/0123456789abcdef"\n'
  printf '  status: %s\n' "$2"
}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  poll)
    # A real blocking listener: it returns only when the trigger appears, so a
    # live owner in these tests is a live process rather than a timing artifact.
    # Both waits are bounded, so a listener that escapes its test cannot keep
    # spawning processes for as long as the host stays up.
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "$state/poll-trigger" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    printf 'session:\n  status: ended\n'
    if [ -e "$state/hold-after-terminal" ]; then
      : > "$state/terminal-emitted"
      while [ -e "$state/hold-after-terminal" ]; do
        [ "$SECONDS" -lt "$limit" ] || exit 75
        sleep 0.05
      done
    fi
    exit 0
    ;;
  '')
    if [ -e "$state/end-before-next-list" ]; then
      : > "$state/open"
      rm -f "$state/end-before-next-list"
    fi
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$state/open" ]; then
      while IFS= read -r listed; do
        [ -n "$listed" ] || continue
        printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$listed"
      done < "$state/open"
    fi
    exit 0
    ;;
  end) : > "$state/open"; printf 'session:\n  status: ended\n'; exit 0 ;;
esac
file=$1
shift
reopen=0
for arg in "$@"; do [ "$arg" != --reopen ] || reopen=1; done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
if [ -e "$state/user-ended" ] && [ "$reopen" = 0 ]; then
  emit "$real" user-ended
  exit 0
fi
if [ -e "$state/refuse-reopen" ]; then
  emit "$real" user-ended
  exit 0
fi
rm -f -- "$state/user-ended"
printf '%s\n' "$real" > "$state/open"
jq -n --arg file "$real" \
  '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
  > "$state/state.json"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

end_session_as_captain() { : > "$1/lavish-state/user-ended"; : > "$1/lavish-state/open"; }

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "recommend_value": "yes",
      "allow_freeform": true,
      "case_against": "It slows the first admission by a day."
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "inbox": [],
  "later": [],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "alarm"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown charted kind was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "warning"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a dispatchable warning row was accepted"

  write_valid_payload "$data"
  jq '.charted_warning_more = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative omitted-warning count was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].subject = {"artifact":"quota-axi","version":"0.1"}' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an invalid structured version subject was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","state":"working",
    "kind":"ship","doing":"implementing"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an underway row without an explicit name marker was accepted"

  for invalid_filed in "last Tuesday" "2026-13-01" "2026-08-14T99:30:00Z" "2026-02-29"; do
    write_valid_payload "$data"
    jq --arg filed "$invalid_filed" '.charted[0].filed = $filed' "$data" > "$data.tmp" \
      && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid filed date was accepted: $invalid_filed"
  done

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work","outcome": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: apart from the reconcile choice the build adds to every
  # decision card, the payload extracted from the built page is the same JSON
  # document, and the escaped </script> string can no longer terminate the
  # data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$home/extracted.json" > "$home/stripped.json"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/stripped.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ -z "${1:-}" ]; then
  printf 'sessions[1]{file,status,url,pending_prompts}:\n'
  [ ! -s "$FM_HOME/order-open" ] \
    || printf '  %s,open,"http://127.0.0.1/session/order",0\n' "$(cat "$FM_HOME/order-open")"
  exit 0
fi
if [ "${1:-}" != poll ]; then
  real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  printf '%s\n' "$real" > "$FM_HOME/order-open"
  mkdir -p "$LAVISH_AXI_STATE_DIR"
  jq -n --arg file "$real" \
    '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:14387/session/0123456789abcdef"}}}' \
    > "$LAVISH_AXI_STATE_DIR/state.json"
  printf 'session:\n  status: opened\n'
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"schema\\": \\"fm-bearings-answer.v1\\",\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"selection\\": \\"yes\\",\\n  \\"note\\": \\"\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  ORDER_PROOF_HOLD="$hold" run_board "$home" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  # Arm starts the listener, which captures the answer and closes the hold on
  # its own schedule after build returns.
  for _ in $(seq 1 100); do
    show=$(cd "$home" && tasks-axi show "$hold" --full) \
      || fail "the order-proof captain hold disappeared"
    case "$show" in *"state: done"*) break ;; esac
    sleep 0.1
  done
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

# The build prints the session URL in the phone-openable form the host's
# `tailscale serve` publishes (bin/fm-lavish-url.sh), while its own liveness
# check still reads lavish-axi's raw output, and prints the raw URL when no
# serve origin exists.
test_build_prints_the_phone_openable_session_url() {
  local home data out
  home=$(make_home phone-url)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"TCP":{"8443":{"HTTPS":true}},"Web":{"host.tail0.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4387"}}}}}'
SH
  chmod +x "$home/fakebin/tailscale"
  out=$(FM_TAILSCALE="$home/fakebin/tailscale" run_board "$home" build "$data") || fail "a valid payload did not build: $out"
  assert_contains "$out" "https://host.tail0.ts.net:8443/session/0123456789abcdef" "the build did not print the phone-openable session URL: $out"
  case "$out" in
    *"http://127.0.0.1:4387/session/"*) fail "the build still printed the raw session URL: $out" ;;
  esac
  assert_contains "$out" "armed: " "the rewrite changed what the build armed: $out"
  out=$(run_board "$home" build "$data") || fail "a rebuild with no tailscale did not build: $out"
  assert_contains "$out" "http://127.0.0.1:4387/session/0123456789abcdef" "with no serve origin the build did not print the raw session URL: $out"
  pass "a board build prints the phone-openable session URL and keeps the raw one without a serve origin"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_charted_kind_is_optional_and_accepts_both_values() {
  local home data
  home=$(make_home chartedkind)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted = [
        {"id":"a","repo":"sample","title":"Queued","reason":"","dispatchable":true},
        {"id":"b","repo":"sample","title":"Queued too","reason":"gated","dispatchable":true,"kind":"queued"},
        {"id":"c","repo":"sample","title":"Integrity notice","reason":"main inventory","dispatchable":false,"kind":"warning"}
      ] | .charted_warning_more = 2' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "an omitted, queued, and warning charted kind was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.charted[] | .kind // "queued"]) == ["queued", "queued", "warning"]
      and .charted_warning_more == 2
  ' >/dev/null || fail "the built board did not carry the charted kinds and omitted-warning count it was given"
  pass "charted kind is optional and accepts queued and warning"
}


# --- part 1: never arm a poll on an ended session ---------------------------

test_build_reopens_a_session_the_captain_ended() {
  local home data board out sid claim old_pid old_token new_pid new_token
  home=$(make_home ended-session)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")
  claim="$home/procevent-claims/$sid.claim"
  old_pid=$(sed -n '2p' "$claim")
  old_token=$(sed -n '3p' "$claim")

  # The reported case: the captain ends the board from the browser, so opening
  # it again keeps the same session id, reports it ended, and EXITS 0. A build
  # that trusts the exit status arms a poll nothing can ever attach to.
  : > "$home/lavish-state/hold-after-terminal"
  : > "$home/lavish-state/poll-trigger"
  for _ in $(seq 1 100); do
    [ -e "$home/lavish-state/terminal-emitted" ] && break
    sleep 0.05
  done
  [ -e "$home/lavish-state/terminal-emitted" ] \
    || fail "the old listener did not receive its terminal result"
  rm -f "$home/lavish-state/poll-trigger"
  end_session_as_captain "$home"
  out=$(run_board "$home" build "$data") || fail "the rebuild refused a recoverable ended session"
  rm -f "$home/lavish-state/hold-after-terminal"
  assert_contains "$out" "session: reopened" \
    "the rebuild did not reopen the ended session: $out"
  [ ! -e "$home/lavish-state/user-ended" ] \
    || fail "the rebuild reported success while the session was still ended"
  new_pid=$(sed -n '2p' "$claim")
  new_token=$(sed -n '3p' "$claim")
  [ "$new_pid" != "$old_pid" ] || [ "$new_token" != "$old_token" ] \
    || fail "the rebuild accepted the pre-reopen source generation"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the reopened board has no live listener"
  pass "a board build reopens a session the captain ended instead of arming a dead one"
}

test_build_reopens_when_an_opened_session_ends_before_listing() {
  local home data out board sid
  home=$(make_home establish-list-race)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  : > "$home/lavish-state/end-before-next-list"
  out=$(run_board "$home" build "$data") || fail "the raced session build failed: $out"
  assert_contains "$out" "session: reopened" \
    "the build trusted an opened response after the server no longer listed it: $out"
  sid=$(run_lavish_source_id "$home" "$board")
  [ -s "$home/lavish-state/open" ] || fail "the raced session was not live before arming"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the replacement session did not receive a live listener"
  pass "build reopens a session that ends between establish and listing"
}

test_build_refuses_to_arm_when_the_session_stays_ended() {
  local home data rc out sid
  home=$(make_home dead-session)
  data="$home/payload.json"
  write_valid_payload "$data"
  # An ended session that will not come back: the build must stop rather than
  # register a poll against it.
  : > "$home/lavish-state/refuse-reopen"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build armed a poll on a session that stayed ended: $out"
  assert_contains "$out" "ended session" "the refusal did not say why: $out"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board to a session that stayed ended"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board against a session that stayed ended"
  pass "build refuses to arm a poll on a session that stays ended"
}

test_build_starts_a_listener_for_an_already_armed_board() {
  local home data board out sid claim
  home=$(make_home relisten)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")

  # Registered is not listening: drop the listener the way a crashed generation
  # would, then rebuild. `already-armed` must not be the end of the story.
  claim="$home/procevent-claims/$sid.claim"
  assert_present "$claim" "the first build left no listener to lose"
  kill -KILL -"$(sed -n '2p' "$claim")" 2>/dev/null || true
  kill -KILL "$(sed -n '2p' "$claim")" 2>/dev/null || true
  sleep 1

  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: $sid" "the rebuild re-registered the source: $out"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the rebuilt board is registered but nothing is listening"
  pass "a rebuild starts a listener when an already-armed board has none"
}

# --- part 2: a landed subject is not a live call ----------------------------

test_build_drops_decision_cards_whose_subject_already_landed() {
  local home data board out
  home=$(make_home landed-cards)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call = [
        {"key":"landed-by-task","type":"decision","repo":"sample","title":"Already shipped",
         "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
         "recommend_value":"yes","allow_freeform":true,"case_against":"No reason to wait."},
        {"key":"timeout-reattach","type":"decision","repo":"sample","title":"Already merged",
         "pr_url":"https://github.com/sample/sample/pull/7",
         "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
         "recommend_value":"yes","allow_freeform":true,"case_against":"No reason to wait."},
        {"key":"quota-version","type":"decision","repo":"sample","title":"Old quota release",
         "subject":{"artifact":"quota-axi","version":"0.1.37"},
         "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
         "recommend_value":"yes","allow_freeform":true,"case_against":"No reason to wait."},
        {"key":"still-open","type":"decision","repo":"sample","title":"Genuinely open",
         "subject":{"artifact":"quota-axi","version":"0.2.0"},
         "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
         "recommend_value":"yes","allow_freeform":true,"case_against":"No reason to wait."}
      ]
      | .landed = [
        {"id":"landed-by-task","repo":"sample","what":"shipped it","outcome":"shipped it","owner":"crew"},
        {"id":"some-other-task","repo":"sample","what":"merged timeout reattach","outcome":"merged timeout reattach","owner":"crew",
         "pr_url":"https://github.com/sample/sample/pull/7"},
        {"id":"quota-release","repo":"sample","what":"published quota-axi","outcome":"published quota-axi","owner":"crew",
         "subject":{"artifact":"quota-axi","version":"0.1.38"}},
        {"id":"unrelated\nstill-open","repo":"sample","what":"unrelated multiline identity","outcome":"unrelated multiline identity","owner":"crew"}
      ]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the hygiene build failed: $out"
  assert_contains "$out" "dropped-landed-card: landed-by-task" \
    "the build did not report dropping the landed work item card: $out"
  assert_contains "$out" "dropped-landed-card: timeout-reattach" \
    "the build did not report dropping the merged timeout/reattach card: $out"
  assert_contains "$out" "dropped-landed-card: quota-version" \
    "the build did not report dropping the superseded quota-axi version card: $out"
  extract_payload "$board" | jq -e '[.captains_call[].key] == ["still-open"]' >/dev/null \
    || fail "the board dropped an open card or kept one whose subject already landed"
  pass "build drops decision cards whose subject already landed and keeps open ones"
}

test_build_keeps_a_decision_absent_from_the_main_backlog() {
  local home data board out
  home=$(make_home remote-decision-card)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  write_valid_payload "$data"
  jq '.captains_call = [{
        "key":"remote-mate-call","type":"decision","repo":"sample",
        "title":"Remote secondmate decision",
        "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
        "recommend_value":"yes","allow_freeform":true,"case_against":"No reason to wait."
      }]
      | .landed = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the remote-card build failed: $out"
  assert_not_contains "$out" "dropped-landed-card: remote-mate-call" \
    "an absent remote card was reported as landed: $out"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.key == "remote-mate-call")] | length == 1
  ' >/dev/null || fail "the hygiene check dropped a decision absent from the main backlog"
  pass "build keeps remote decisions absent from the main backlog"
}

# --- part 3: every decision card offers reconcile ---------------------------

test_build_fails_when_reconcile_cannot_establish_a_listener() {
  local home data out rc sid
  home=$(make_home no-listener)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not establish the listener fixture"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/ps"
  set +e
  out=$(FM_PROC_ROOT_OVERRIDE="$home/no-proc" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  rm -f "$home/fakebin/ps"
  [ "$rc" -ne 0 ] || fail "a build with an uncertain listener reported success: $out"
  assert_contains "$out" "source $sid is not listening after reconcile" \
    "the refusal did not name the source: $out"
  assert_contains "$out" "observed owner: uncertain" \
    "the refusal did not name the observed owner: $out"
  pass "build fails when reconcile cannot prove a live listener"
}

test_every_decision_card_carries_the_reconcile_choice() {
  local home data board
  home=$(make_home reconcile-option)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the reconcile-option build failed"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type == "decision")] | length) > 0
    and ([.captains_call[]
      | select(.type == "decision")
      | ([.options[] | select(.value == "reconcile")] | length) == 1
        and ([.options[] | select(.value == "reconcile") | .label | length > 0] | all)] | all)
  ' >/dev/null || fail "a decision card was published without the reconcile choice"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type != "decision")
      | .options[] | select(.value == "reconcile")] | length) == 0
  ' >/dev/null || fail "reconcile was injected into a non-decision card"
  pass "every decision card carries exactly one reconcile choice"
}

test_build_refuses_a_payload_that_occupies_the_reconcile_value() {
  local home data rc out
  home=$(make_home reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[0].options += [{"value":"reconcile","label":"Something else"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a payload occupying the reserved reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused payload still produced a board"
  pass "build refuses a payload that occupies the reserved reconcile value"
}

test_build_refuses_a_nondecision_reconcile_value() {
  local home data rc out
  home=$(make_home merge-reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[1].options += [{"value":"reconcile","label":"Merge action"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a merge card occupying the reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused merge card still produced a board"
  pass "build reserves reconcile across non-decision cards"
}

# --- part 4: a decision card offers a real choice ---------------------------

# Build <data> after applying <jq-filter> to the valid payload, and require a
# refusal that names <expected> and leaves no board behind.
assert_weak_card_refused() {  # <home> <jq-filter> <expected> <case>
  local home=$1 data="$1/payload.json" rc out
  write_valid_payload "$data"
  jq "$2" "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "$4 was accepted"
  assert_contains "$out" "$3" "the refusal for $4 did not name what is missing: $out"
  assert_absent "$home/.lavish/bearings-board.html" "$4 still produced a board"
}

test_build_refuses_a_decision_card_without_a_real_choice() {
  local home key
  home=$(make_home weak-decision)
  write_valid_payload "$home/payload.json"
  key=$(jq -r '.captains_call[0].key' "$home/payload.json")
  assert_weak_card_refused "$home" \
    '.captains_call[0].options = [{"value":"done","label":"Done"}]' \
    "$key: needs at least two authored options (has 1), a recommend_value naming one of its options" \
    "a Done-only decision card"
  assert_weak_card_refused "$home" \
    '.captains_call[0].options = [{"value":"done","label":"Done"},{"value":"reconcile","label":"Reconcile"}]
      | .captains_call[0].recommend_value = "done"' \
    "does not satisfy fm-bearings-board.v1" \
    "a decision card padded with an authored reconcile option"
  assert_weak_card_refused "$home" 'del(.captains_call[0].recommend_value)' \
    "$key: needs a recommend_value naming one of its options" \
    "a decision card with no recommendation"
  assert_weak_card_refused "$home" '.captains_call[0].recommend_value = "maybe"' \
    "$key: needs a recommend_value naming one of its options" \
    "a decision card recommending an option it does not offer"
  assert_weak_card_refused "$home" 'del(.captains_call[0].allow_freeform)' \
    "$key: needs allow_freeform true" \
    "a decision card without the free-text field"
  assert_weak_card_refused "$home" '.captains_call[0].allow_freeform = false' \
    "$key: needs allow_freeform true" \
    "a decision card that turns the free-text field off"
  assert_weak_card_refused "$home" \
    '.captains_call[0].options = [{"value":"done","label":"Done"},{"value":"done","label":"Done now"}]
      | .captains_call[0].recommend_value = "done"' \
    "$key: needs distinct option values" \
    "a decision card repeating one option value"
  pass "build refuses a decision card without two authored options, a recommendation, and free text"
}

test_a_decision_card_carries_the_case_against_its_recommendation() {
  local home key data out long
  home=$(make_home case-against)
  write_valid_payload "$home/payload.json"
  key=$(jq -r '.captains_call[0].key' "$home/payload.json")
  long=$(printf 'x%.0s' $(seq 1 301))
  assert_weak_card_refused "$home" 'del(.captains_call[0].case_against)' \
    "$key: needs a one-line case_against of at most 300 characters" \
    "a decision card with no case against"
  assert_weak_card_refused "$home" '.captains_call[0].case_against = "  "' \
    "$key: needs a one-line case_against of at most 300 characters" \
    "a decision card with a blank case against"
  assert_weak_card_refused "$home" '.captains_call[0].case_against = "one\ntwo"' \
    "$key: needs a one-line case_against of at most 300 characters" \
    "a decision card whose case against runs over two lines"
  assert_weak_card_refused "$home" ".captains_call[0].case_against = \"$long\"" \
    "$key: needs a one-line case_against of at most 300 characters" \
    "a decision card whose case against is longer than one line"
  assert_weak_card_refused "$home" '.captains_call[0].case_against = 7' \
    "does not satisfy fm-bearings-board.v1" \
    "a decision card whose case against is not text"
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a decision card with its case against refused the board: $out"
  out=$(run_board "$home" published) || fail "published could not read the board it just built"
  printf '%s' "$out" | jq -e --arg key "$key" \
    '.captains_call[] | select(.key == $key) | .case_against == "It slows the first admission by a day."' \
    >/dev/null || fail "published did not return the built card's case against: $out"
  pass "a decision card must carry a one-line case against, and published returns it for the next build"
}

test_published_fails_when_no_board_was_built() {
  local home rc out
  home=$(make_home no-board-published)
  set +e; out=$(run_board "$home" published 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "published succeeded with no board built"
  assert_contains "$out" "no board has been built" "published did not say why it failed: $out"
  pass "published fails plainly when no board has been built"
}

test_a_later_option_carries_the_date_it_comes_back() {
  local home key data out
  home=$(make_home later-option)
  write_valid_payload "$home/payload.json"
  key=$(jq -r '.captains_call[0].key' "$home/payload.json")
  assert_weak_card_refused "$home" \
    '.captains_call[0].options += [{"value":"later","label":"Later","hint":"Back next week."}]' \
    "$key: needs an until date on its later option" \
    "a later option with no date to come back on"
  assert_weak_card_refused "$home" \
    '.captains_call[0].options += [{"value":"later","label":"Later","until":"next week"}]' \
    "does not satisfy fm-bearings-board.v1" \
    "a later option whose date is not a date"
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[0].options += [{"value":"later","label":"Later","hint":"Back on the 9th.","until":"2099-03-09"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a dated later option refused the board: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e \
    '.captains_call[0].options | map(select(.value == "later")) == [{"value":"later","label":"Later","hint":"Back on the 9th.","until":"2099-03-09"}]' \
    >/dev/null || fail "the built board lost the later option's date"
  pass "a decision card's later option must carry the date it comes back, and the board keeps it"
}

test_a_weak_card_whose_subject_landed_is_dropped_not_refused() {
  local home data out
  home=$(make_home weak-landed)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"old-done-only","type":"decision","repo":"sample",
        "title":"Already shipped","options":[{"value":"done","label":"Done"},{"value":"done","label":"Done"}]}]
      | .landed = [{"id":"old-done-only","repo":"sample","what":"shipped it","outcome":"shipped it","owner":"crew"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a landed weak card refused the board: $out"
  assert_contains "$out" "dropped-landed-card: old-done-only" "the landed weak card was not dropped: $out"
  pass "a weak decision card whose subject landed is dropped rather than refusing the board"
}

test_merge_and_credential_cards_keep_their_own_shapes() {
  local home data out
  home=$(make_home card-shapes)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[1] |= (del(.recommend_value) | .options = [{"value":"merge","label":"Merge now"}]
        | .allow_freeform = false)
      | .captains_call += [{"key":"credential.sample","type":"credential","repo":"sample",
        "title":"Sample login","options":[{"value":"done","label":"Logged in"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "single-option merge and credential cards were refused: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    [.captains_call[] | select(.type != "decision") | .options | length] == [1, 1]
  ' >/dev/null || fail "the build changed a merge or credential card's options"
  pass "merge and credential cards keep their own option shapes"
}

# One inbox item of each kind the board carries: a worker blocked on the
# captain, and a due captain hold whose actions read value boxes.
INBOX_ITEMS='[
  {"key":"sample-worker","group":"blocking","repo":"sample","title":"Open the sample site",
   "ask":"Sign in so the worker can read it.","since":"2026-08-18T22:00:00Z","inputs":[],
   "actions":[
     {"value":"go","label":"Signed in - go","hint":"The worker reads it now.","effect":"resume-worker","reads":[]},
     {"value":"monday","label":"Do it Monday","hint":"The worker stays parked until Monday 9 am.","effect":"remind-at","at":"2026-08-24T09:00","reads":[]}]},
  {"key":"sample-count","group":"due","due":"2026-08-20","repo":"sample","title":"Count the sample shelf",
   "ask":"Count both sizes.","inputs":[
     {"name":"small","label":"Small","type":"number"},{"name":"large","label":"Large","type":"number"},
     {"name":"day","label":"Back on","type":"date","default":"2026-08-27"}],
   "actions":[
     {"value":"save","label":"Save counts","hint":"Firstmate writes them to the ledger.","effect":"record","reads":["small","large"]},
     {"value":"later","label":"Bring it back","hint":"Back on that day.","effect":"hold-until","reads":["day"]},
     {"value":"never","label":"Not needed","hint":"Closes the item.","effect":"close","reads":[]}]}
]'

test_build_accepts_the_inbox_layout() {
  local home data board
  home=$(make_home inbox-layout)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq --argjson inbox "$INBOX_ITEMS" '.inbox = $inbox
    | .later = [{"id":"sample-later","repo":"sample","title":"[2026-09-01] Arjun: revisit later","group":"dated","back":"2026-09-01"},
                {"id":"sample-held","repo":"sample","title":"Held for him","group":"held"},
                {"id":"sample-unheld","repo":null,"title":"Filed as his","group":"unheld"}]
    | .underway = [{"id":"sample-run","repo":"sample","name":"Sample run","state":"working","kind":"ship",
                    "doing":"in code review","progress":{"done":3,"total":6,"step":"answer the review"}}]
    | .landed = [{"id":"sample-done","repo":"sample","what":"sample change","outcome":"Sample live","owner":"crew",
                  "pr_url":"https://github.com/example/sample/pull/2"}]
    | .charted += [{"id":"sample-dated","repo":"sample","title":"Starts later","reason":"","dispatchable":false,
                    "wait":"date","wait_date":"2026-09-10"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "a valid inbox-first payload was refused"
  extract_payload "$board" | jq -e '(.inbox | length) == 2 and (.later | length) == 3' >/dev/null \
    || fail "the built board lost the inbox or later rows"
  pass "build accepts the inbox-first layout: items, later rows, step progress, outcomes, and queue waits"
}

test_build_names_every_inbox_item_that_does_not_say_what_it_does() {
  local home key=sample-count
  home=$(make_home weak-inbox)
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions = [.inbox[1].actions[0]] | .inbox[1].inputs = .inbox[1].inputs[0:2]" \
    "$key: needs two or three actions (has 1)" "an item with one action"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions[2].hint = \" \"" \
    "$key: needs a hint on action never" "an action with no hint"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions[2].effect = \"pay\"" \
    "$key: needs a known effect on action never (has pay)" "an action with an unknown effect"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions[0].reads = [\"small\",\"ghost\"]" \
    "$key: needs an input named ghost for action save, an action that reads input large" \
    "an action reading a missing input"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions[1].reads = []" \
    "either an until date or one date input on action later" "a deferral with no date"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[0].actions[1].effect = \"close\" | del(.inbox[0].actions[1].at)" \
    "sample-worker: needs no close on action monday, since a blocking item is not a captain hold" \
    "a worker item that closes a hold"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions[2].effect = \"dispatch\"" \
    "$key: needs a one-line brief on dispatch action never" "a dispatch with no brief"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].key = .captains_call[0].key" \
    "needs a key no other item or card uses" "an item sharing a card key"
  assert_weak_card_refused "$home" \
    ".inbox = $INBOX_ITEMS | .inbox[1].actions[2].value = \"reconcile\"" \
    "$key: needs no action named reconcile, which is reserved" "an item occupying reconcile"
  pass "build names every inbox item whose actions do not say plainly what the fleet does"
}

test_build_refuses_the_new_fields_out_of_shape() {
  local home data rc out case filter
  home=$(make_home new-fields)
  data="$home/payload.json"
  while IFS='|' read -r case filter; do
    write_valid_payload "$data"
    jq "$filter" "$data" > "$data.tmp" && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "build accepted $case"
    assert_contains "$out" "does not satisfy fm-bearings-board.v1" "the refusal of $case did not name the contract: $out"
  done <<'EOF'
a payload with no inbox|del(.inbox)
a payload with no later rows|del(.later)
a landed row with no outcome|.landed = [{"id":"x","repo":"s","what":"w","owner":"o"}]
step progress past its total|.underway = [{"id":"x","repo":"s","name":"n","state":"working","kind":"ship","doing":"d","progress":{"done":7,"total":6}}]
a dated later row with no date|.later = [{"id":"x","repo":"s","title":"t","group":"dated"}]
a due item with no due date|.inbox = [{"key":"x","group":"due","repo":"s","title":"t","ask":"a","inputs":[],"actions":[]}]
an unknown queue wait|.charted[0].wait = "someday"
a card link that is not a web page|.captains_call[0].link = {"url":"file:///tmp/x.html","label":"Atlas board"}
a card link with no label|.captains_call[0].link = {"url":"http://100.119.38.2:4387/session/1"}
a link on a merge card|.captains_call[0].type = "merge" | .captains_call[0].risk = "low" | .captains_call[0].link = {"url":"http://h/s","label":"l"}
EOF
  pass "build refuses each new layout field out of shape"
}

test_build_if_changed_skips_an_unchanged_board() {
  local home data board out before
  home=$(make_home if-changed)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  out=$(run_board "$home" build --if-changed "$data") || fail "the first conditional build failed"
  assert_contains "$out" "served: $board" "a conditional build with no prior board did not publish"
  before=$(extract_payload "$board" | jq -r .generated)
  jq '.generated = "2026-08-19T05:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build --if-changed "$data") || fail "the unchanged conditional build failed"
  assert_contains "$out" "unchanged: $board" "a board that differs only in its timestamp was republished: $out"
  [ "$(extract_payload "$board" | jq -r .generated)" = "$before" ] \
    || fail "an unchanged conditional build rewrote the board"
  end_session_as_captain "$home"
  out=$(run_board "$home" build --if-changed "$data") || fail "the conditional build over an ended session failed"
  assert_not_contains "$out" "unchanged:" "an unchanged board whose session had ended was not reopened: $out"
  assert_contains "$out" "session: reopened" "an ended board session was not reopened by the conditional build: $out"
  jq '.charted[0].title = "Queued work, renamed"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build --if-changed "$data") || fail "the changed conditional build failed"
  assert_not_contains "$out" "unchanged:" "a changed board was skipped: $out"
  extract_payload "$board" | jq -e '.charted[0].title == "Queued work, renamed"' >/dev/null \
    || fail "a changed conditional build did not publish the change"
  pass "build --if-changed republishes only when the composed board changed or its session ended"
}

current_prune_slot() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-backlog-prune.sh" schedule | jq -r .slot
}

with_prune_card() {  # <path> <slot>
  jq --arg slot "$2" '.prune = {slot:$slot, title:"Weekly backlog prune",
      ask:"Two fleet items sat untouched for two weeks.", more:0,
      candidates:[{id:"stale-one", title:"Old thing one", repo:"fleet", touched:"2026-09-01"},
                  {id:"stale-two", title:"Old thing two", repo:null, touched:"2026-09-03"}]}' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

test_build_records_the_prune_offer_and_keys_the_card() {
  local home data board slot key rc out case filter
  home=$(make_home prune)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  slot=$(current_prune_slot "$home")
  write_valid_payload "$data"
  with_prune_card "$data" "$slot"
  jq '.prune.key = "prune.composed"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "a payload with a prune card was refused"
  key=$(extract_payload "$board" | jq -r '.prune.key')
  printf '%s' "$key" | grep -Eq "^prune\.$slot\.[0-9a-f]{8}\$" \
    || fail "the built card does not carry the offer key build recorded: $key"
  jq -e '.ids == ["stale-one","stale-two"]' "$home/state/backlog-prune/offers/$key.json" >/dev/null \
    || fail "build did not record exactly the card's list as the offer"

  write_valid_payload "$data"
  with_prune_card "$data" 2000-01-03
  out=$(run_board "$home" build "$data" 2>&1) || fail "a stale prune card refused the whole board: $out"
  assert_contains "$out" "dropped-prune-card: slot 2000-01-03 is not the current weekly slot" \
    "the stale card was not named as dropped: $out"
  extract_payload "$board" | jq -e 'has("prune") | not' >/dev/null || fail "a stale prune card shipped"

  while IFS='|' read -r case filter; do
    write_valid_payload "$data"
    with_prune_card "$data" "$slot"
    jq "$filter" "$data" > "$data.tmp" && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "build accepted $case"
    assert_contains "$out" "does not satisfy fm-bearings-board.v1" "the refusal of $case did not name the contract: $out"
  done <<'EOF2'
a prune card with no candidates|.prune.candidates = []
a prune card listing a row twice|.prune.candidates[1].id = "stale-one"
a prune candidate with no touched date|del(.prune.candidates[0].touched)
a prune candidate with no repo marker|del(.prune.candidates[0].repo)
a prune card with no ask|.prune.ask = ""
EOF2
  pass "build records the prune card's exact list as an offer and keys the card with it, and drops a stale card"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_charted_kind_is_optional_and_accepts_both_values
test_build_injects_binds_then_arms
test_build_prints_the_phone_openable_session_url
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
test_build_reopens_a_session_the_captain_ended
test_build_reopens_when_an_opened_session_ends_before_listing
test_build_refuses_to_arm_when_the_session_stays_ended
test_build_starts_a_listener_for_an_already_armed_board
test_build_drops_decision_cards_whose_subject_already_landed
test_build_keeps_a_decision_absent_from_the_main_backlog
test_build_fails_when_reconcile_cannot_establish_a_listener
test_every_decision_card_carries_the_reconcile_choice
test_build_refuses_a_payload_that_occupies_the_reconcile_value
test_build_refuses_a_nondecision_reconcile_value
test_build_refuses_a_decision_card_without_a_real_choice
test_a_decision_card_carries_the_case_against_its_recommendation
test_published_fails_when_no_board_was_built
test_a_later_option_carries_the_date_it_comes_back
test_merge_and_credential_cards_keep_their_own_shapes
test_a_weak_card_whose_subject_landed_is_dropped_not_refused
test_build_accepts_the_inbox_layout
test_build_names_every_inbox_item_that_does_not_say_what_it_does
test_build_refuses_the_new_fields_out_of_shape
test_build_if_changed_skips_an_unchanged_board
test_build_records_the_prune_offer_and_keys_the_card

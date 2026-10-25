#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - its sections, items, rows, and the answers its taps queue - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}


# Dates sit far from today on purpose: the board groups due work against the
# viewer's own clock, so a fixture that is not relative to it would drift.
PAST=2001-01-02
SOON=2099-03-04
LATER_DAY=2099-03-09

# Every kind of row the inbox-first board renders, built through the real
# `build` so the payload is the one its validator accepts.
full_payload() {  # <path>
  jq -n --arg past "$PAST" --arg soon "$SOON" --arg later "$LATER_DAY" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2099-03-01T14:30:00Z", prs_live:false,
    captains_call:[
      {key:"sample-tier", type:"decision", repo:"sample", title:"Pick the tier", about:"It renews soon.",
       decide:"Which tier?", options:[
         {value:"keep", label:"Keep it", hint:"Nothing changes."},
         {value:"upgrade", label:"Upgrade", hint:"Firstmate drafts it for your OK."}],
       recommend_value:"keep", allow_freeform:true},
      {key:"sample-domain", type:"decision", repo:"sample", title:"Renew the domain", about:"Unused.",
       decide:"Renew?", options:[
         {value:"lapse", label:"Let it lapse", hint:"Nothing renews."},
         {value:"renew", label:"Renew", hint:"Firstmate renews it."}],
       recommend_value:"lapse", allow_freeform:true, close:"release"}],
    inbox:[
      {key:"sample-worker", group:"blocking", repo:"sample", title:"Open the sample site",
       ask:"Sign in so the worker can read it.", since:"2099-02-28T20:00:00Z",
       pr_url:"https://github.com/example/sample/pull/844", inputs:[],
       actions:[
         {value:"go", label:"Signed in - go", hint:"The worker reads it now.", effect:"resume-worker", reads:[]},
         {value:"monday", label:"Do it Monday", hint:"The worker stays parked until Monday.", effect:"remind-at", at:"2099-03-02T09:00", reads:[]}]},
      {key:"sample-count", group:"due", due:$soon, repo:"sample", title:"Count the shelf", ask:"Count both sizes.",
       inputs:[{name:"small", label:"Small", type:"number"}, {name:"large", label:"Large", type:"number"},
               {name:"day", label:"Back on", type:"date", default:$later}],
       actions:[
         {value:"save", label:"Save counts", hint:"Firstmate writes them to the ledger.", effect:"record", reads:["small","large"]},
         {value:"later", label:"Bring it back", hint:"Back on that day.", effect:"hold-until", reads:["day"]},
         {value:"never", label:"Not needed", hint:"Closes the item.", effect:"close", reads:[]}]},
      {key:"sample-send", group:"due", due:$soon, repo:"sample", title:"Send the amendment", ask:"It is drafted.",
       close:"release", inputs:[],
       actions:[
         {value:"sent", label:"Sent it", hint:"Firstmate watches for the reply.", effect:"close", reads:[]},
         {value:"thu", label:"Push to Thursday", hint:"Back on Thursday.", effect:"hold-until", until:$later, reads:[]}]},
      {key:"sample-late", group:"due", due:$past, repo:"sample", title:"Read the old notice", ask:"It was due long ago.",
       inputs:[{name:"when", label:"When", type:"datetime-local"}],
       actions:[
         {value:"now", label:"Read it now", hint:"Firstmate reads it with you.", effect:"dispatch", brief:"Attended read", reads:[]},
         {value:"book", label:"Book this time", hint:"Firstmate pings you then.", effect:"remind-at", reads:["when"]}]}],
    later:[
      {id:"later-dated", repo:"sample", title:"[2099-04-01] Arjun: revisit the plan", group:"dated", back:"2099-04-01"},
      {id:"later-held", repo:"sample", title:"Weigh the mats", group:"held"},
      {id:"later-unheld", repo:null, title:"Find the property id", group:"unheld"}],
    underway:[
      {id:"run-a", repo:"sample", name:"Sample run", state:"working", kind:"ship", doing:"in code review",
       progress:{done:3, total:6, step:"answer the review"}},
      {id:"run-b", repo:"sample", name:"Other run", state:"working", kind:"ship", doing:"building"}],
    landed:[
      {id:"done-a", repo:"sample", what:"long task title", outcome:"Sample live", owner:"crew",
       pr_url:"https://github.com/example/sample/pull/2"},
      {id:"done-b", repo:"sample", what:"scout", outcome:"Mockup approved", owner:"crew", artifact:"data/x/report.md"}],
    charted:[
      {id:"q-ready", repo:"sample", title:"Ready work", reason:"", dispatchable:true, wait:"none"},
      {id:"q-date", repo:"sample", title:"Dated work", reason:"", dispatchable:false, wait:"date", wait_date:$later},
      {id:"q-was", repo:"sample", title:"Lapsed date", reason:"", dispatchable:false, wait:"date", wait_date:$past},
      {id:"q-out", repo:"sample", title:"Vendor reply", reason:"", dispatchable:false, wait:"outside"},
      {id:"q-work", repo:"sample", title:"After the cutover", reason:"", dispatchable:false, wait:"work"},
      {id:"q-idle", repo:"sample", title:"Not begun", reason:"", dispatchable:false},
      {id:"main-inventory", repo:null, title:"Main inventory integrity", reason:"main inventory", dispatchable:false, kind:"warning"}],
    charted_more:2}' > "$1"
}

build_board() {  # <home> <payload>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$2" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
}

# Render the built board, optionally after taps (<steps-json>) and with a seeded
# viewer storage (<storage-json>), and print what the renderer produced.
render() {  # <home> [<steps-json>] [<storage-json>]
  local home=$1
  printf '%s\n' "${2:-[]}" > "$home/steps.json"
  printf '%s\n' "${3:-{\}}" > "$home/storage.json"
  node "$HARNESS" "$home/.lavish/bearings-board.html" "$home/steps.json" "$home/storage.json" \
    || fail "the built board could not be rendered"
}

full_board() {  # <name> -> home with the full payload built
  local home
  home=$(make_home "$1")
  full_payload "$home/payload.json"
  build_board "$home" "$home/payload.json"
  printf '%s\n' "$home"
}

test_the_inbox_comes_first_in_folding_sections() {
  local home out
  home=$(full_board layout)
  out=$(render "$home")
  printf '%s' "$out" | jq -e --arg soon "$SOON" '
    .error == ""
      and .inboxCount == "6"
      and (.headline | startswith("6 things wait on you. "))
      and ([.sections[] | select(.depth == 0) | .key]
        == ["blocking", "decisions", "overdue", "due-" + $soon, "later", "underway", "landed", "queued"])
      and ([.sections[] | select(.depth == 0) | {key, open}] | map(select(.open == (.key != "later"))) | length) == 8
      and ([.sections[] | select(.key == "due-" + $soon) | .items[].key] == ["sample-count", "sample-send"])
      and ([.sections[] | select(.key == "overdue") | .title, .count] == ["Overdue", "1"])
      and ([.sections[] | select(.key == "later") | .count] == ["3 · nothing due this week"])
      and (.fleetSum == "2 underway · 2 landed · 8 queued")
  ' >/dev/null || fail "the board did not lead with the captain's inbox in folding sections: $out"
  pass "the inbox comes first, grouped by kind and due date, and every section but Later opens"
}

test_an_inbox_item_shows_its_own_actions_and_value_boxes() {
  local home out
  home=$(full_board item-shape)
  out=$(render "$home")
  printf '%s' "$out" | jq -e '
    ([.sections[].items[] | select(.key == "sample-count")][0]) as $count
    | ([.sections[].items[] | select(.key == "sample-worker")][0]) as $worker
    | ($count.title == "Count the shelf" and $count.ask == "Count both sizes." and $count.meta == "sample")
      and ([$count.actions[] | {value, main}] == [{value:"save", main:true}, {value:"later", main:false}, {value:"never", main:false}])
      and ($count.actions[0].hint == "Firstmate writes them to the ledger.")
      and ([$count.inputs[] | {name, type}] == [{name:"small", type:"number"}, {name:"large", type:"number"}, {name:"day", type:"date"}])
      and ($count.inputs[2].value != "")
      and ($worker.meta | test("^sample · worker waiting since .+ · PR 844$"))
      and ($worker.radios == [])
  ' >/dev/null || fail "an inbox item did not render its own actions and value boxes: $out"
  pass "an inbox item shows its title, ask, area, its own actions with hints, and its value boxes"
}

test_an_action_carries_its_values_note_and_route() {
  local home out
  home=$(full_board action-answer)
  out=$(render "$home" '[
    {"do":"action","key":"sample-count","value":"save"},
    {"do":"action","key":"sample-count","value":"save","values":{"small":"14","large":"9"},"note":"shelf B"},
    {"do":"action","key":"sample-send","value":"thu"},
    {"do":"action","key":"sample-late","value":"book","values":{"when":"2099-03-05T10:00"}}]')
  printf '%s' "$out" | jq -e --arg later "$LATER_DAY" '
    (.prompts | length) == 3
      and (.prompts[0].data == {schema:"fm-bearings-answer.v1", question:"sample-count", group:"due",
            action:"save", effect:"record", values:{small:"14", large:"9"}, note:"shelf B",
            receipt:{item:"Count the shelf", action:"Save counts", detail:"Small: 14, Large: 9", note:"shelf B"}})
      and (.prompts[0].line == "Count the shelf → Save counts · Small: 14, Large: 9 (shelf B)")
      and (.prompts[1].data | .effect == "hold-until" and .until == $later and .note == "")
      and (.prompts[2].data | .effect == "remind-at" and .at == "2099-03-05T10:00" and .values == {when:"2099-03-05T10:00"})
      and ([.sections[].items[] | select(.key == "sample-count")][0] | .sent and .pill == "✓ Save counts")
  ' >/dev/null || fail "an action did not queue its values, note, and route: $out"
  pass "an action queues one answer with its values, note, effect, and resolved date"
}

test_an_action_with_an_empty_box_refuses_and_marks_it() {
  local home out
  home=$(full_board empty-box)
  out=$(render "$home" '[{"do":"action","key":"sample-count","value":"save","values":{"small":"3"}}]')
  printf '%s' "$out" | jq -e '
    (.prompts | length) == 0
      and ([.sections[].items[] | select(.key == "sample-count")][0]
        | (.sent | not) and ([.inputs[] | select(.need) | .name] == ["large"]))
      and .focused == "large"
  ' >/dev/null || fail "an action with an empty value box was queued or did not mark the box: $out"
  pass "an action whose value box is empty refuses, marks that box, and focuses it"
}

test_a_note_alone_is_sent_as_the_captains_words() {
  local home out
  home=$(full_board note-only)
  out=$(render "$home" '[
    {"do":"note","key":"sample-worker","note":"   "},
    {"do":"note","key":"sample-worker","note":"do GA4 first"},
    {"do":"note","key":"sample-tier","note":"neither, ask Sunita"}]')
  printf '%s' "$out" | jq -e '
    (.prompts | length) == 2
      and (.prompts[0].data == {schema:"fm-bearings-answer.v1", question:"sample-worker", group:"blocking",
            action:"", values:{}, note:"do GA4 first",
            receipt:{item:"Open the sample site", action:"", detail:"", note:"do GA4 first"}})
      and (.prompts[0].line == "Open the sample site → “do GA4 first”")
      and (.prompts[1].data | .question == "sample-tier" and .selection == "" and .note == "neither, ask Sunita"
            and (has("close") | not))
      and ([.sections[].items[] | select(.key == "sample-worker")][0].pill == "✓ Your note")
  ' >/dev/null || fail "a note sent alone did not travel as the captain's own words: $out"
  printf '%s' "$(render "$home" '[{"do":"note","key":"sample-worker","note":""}]')" | jq -e '
    (.prompts | length) == 0 and ([.sections[].items[] | select(.key == "sample-worker")][0].noteNeed)
  ' >/dev/null || fail "Send note with no words was queued or not marked"
  pass "Send note sends the captain's words alone on items and cards, and refuses an empty note"
}

test_a_decision_card_opens_on_its_recommendation() {
  local home out
  home=$(full_board card)
  out=$(render "$home" '[
    {"do":"answer","key":"sample-tier","note":"for now"},
    {"do":"answer","key":"sample-domain","pick":"renew"}]')
  printf '%s' "$out" | jq -e '
    ([.sections[] | select(.key == "decisions") | .items[0].radios[] | {value, checked, recommended}]
      == [{value:"keep", checked:true, recommended:true}, {value:"upgrade", checked:false, recommended:false},
          {value:"reconcile", checked:false, recommended:false}])
      and (.prompts[0].data | .question == "sample-tier" and .selection == "keep" and .note == "for now")
      and (.prompts[1].data | .question == "sample-domain" and .selection == "renew" and .close == "release")
  ' >/dev/null || fail "a decision card did not open on its recommendation or send its pick: $out"
  pass "a decision card opens with its recommendation chosen and sends the chosen option with its note"
}

test_take_all_recommendations_confirms_then_sends_one_answer_per_card() {
  local home out
  home=$(full_board take-all)
  out=$(render "$home" '[{"do":"take-all"}]')
  printf '%s' "$out" | jq -e '
    .takeAll.hidden == false and .takeAll.label == "Take all 2 recommendations"
      and .takeAll.confirm == ["Pick the tier → Keep it", "Renew the domain → Let it lapse"]
      and (.prompts | length) == 0
  ' >/dev/null || fail "take all did not list what it would send before sending: $out"
  out=$(render "$home" '[
    {"do":"answer","key":"sample-tier","pick":"upgrade","note":"x"},
    {"do":"take-all"}]')
  printf '%s' "$out" | jq -e '.takeAll.hidden == true and .takeAll.confirm == null' >/dev/null \
    || fail "take all stayed offered with only one open card: $out"
  out=$(render "$home" '[{"do":"take-all"},{"do":"confirm"}]')
  printf '%s' "$out" | jq -e '
    ([.prompts[].data | {question, selection}] == [{question:"sample-tier", selection:"keep"}, {question:"sample-domain", selection:"lapse"}])
  ' >/dev/null || fail "confirming take all did not send each card its own recommended answer: $out"
  pass "take all recommendations confirms the list, then sends one keyed answer per open card"
}

test_take_all_carries_each_cards_typed_note() {
  local home out
  home=$(full_board take-all-note)
  out=$(render "$home" '[
    {"do":"type","key":"sample-domain","note":"lapse it for good"},
    {"do":"take-all"},
    {"do":"confirm"}]')
  printf '%s' "$out" | jq -e '
    ([.prompts[].data | {question, note}]
      == [{question:"sample-tier", note:""}, {question:"sample-domain", note:"lapse it for good"}])
  ' >/dev/null || fail "take all dropped a note typed on its card: $out"
  pass "a note typed on a card rides with that card when all recommendations are taken"
}

test_sections_remember_their_fold_per_viewer() {
  local home out
  home=$(full_board folds)
  out=$(render "$home" '[{"do":"toggle","sec":"underway"}]' '{"bb-sec:later":"1","bb-sec:blocking":"0"}')
  printf '%s' "$out" | jq -e '
    ([.sections[] | select(.key == "later" or .key == "blocking" or .key == "underway") | {key, open}]
      == [{key:"blocking", open:false}, {key:"later", open:true}, {key:"underway", open:false}])
      and .storage["bb-sec:underway"] == "0"
  ' >/dev/null || fail "a section did not keep its fold per viewer: $out"
  pass "every section reads and writes its fold under a stable per-viewer key"
}

test_later_and_the_fleet_read_as_plain_words() {
  local home out
  home=$(full_board fleet)
  out=$(render "$home")
  printf '%s' "$out" | jq -e --arg soon "$SOON" '
    ([.sections[] | select(.key == "later")][0]) as $later
    | ([.sections[] | select(.key == "underway")][0]) as $uw
    | ([.sections[] | select(.key == "landed")][0]) as $ld
    | ([.sections[] | select(.key == "queued")][0]) as $q
    | ([.sections[] | select(.key == "queued-all")][0]) as $all
    | ($later.headings | length) == 3
      and ($later.headings[1:] == ["Held for you, no date 1", "Filed as yours, never held 1"])
      and ($later.rows[0] | .title == "revisit the plan" and (.meta | startswith("2099-04-01 · back ")))
      and ($uw.rows[0] | .title == "Sample run" and .meta == "sample · in code review" and .steps == "3/6 · answer the review")
      and ($uw.rows[1].steps == null)
      and ($uw.asides == ["1 more waits on you above."])
      and ($ld.rows[0] | .title == "Sample live" and .right == "PR 2")
      and ($ld.rows[1] | .title == "Mockup approved" and .meta == "sample · report")
      and ($q.count == "8 · 1 ready")
      and ($q.headings == ["Needs repair", "Ready to start now:"])
      and ([$q.rows[] | select(.pick) | .title] == ["Ready work"])
      and ($all.open == false and $all.title == "Show all 8")
      and ([$all.headings[]] == ["Waits on a date 2", "Waits on someone outside 1", "Waits on other work 1", "Not started 1"])
      and ([$all.rows[] | .meta][0:2] | (.[0] | startswith("from ")) and (.[1] | startswith("was due ")))
      and ($all.asides == ["+2 more queued - ask firstmate for the full chart"])
  ' >/dev/null || fail "Later or the fleet strip did not read as plain words: $out"
  pass "Later and the fleet strip show full plain titles, step bars, outcomes, and a folded queue"
}

test_an_empty_board_says_so_in_each_place() {
  local home out
  home=$(make_home empty)
  jq -n '{schema:"fm-bearings-board.v1", home:"render-home", generated:"2099-03-01T14:30:00Z", prs_live:false,
    captains_call:[], inbox:[], later:[], underway:[], landed:[], charted:[]}' > "$home/payload.json"
  build_board "$home" "$home/payload.json"
  out=$(render "$home")
  printf '%s' "$out" | jq -e '
    .inboxCount == "0" and (.headline | startswith("0 things wait on you."))
      and ([.sections[] | {key, empty}] == [
        {key:"decisions", empty:["No open decisions."]},
        {key:"underway", empty:["Nothing is underway."]},
        {key:"landed", empty:["No recent completions are in the current baseline."]},
        {key:"queued", empty:["Nothing is queued."]}])
  ' >/dev/null || fail "an empty board did not say so in each place: $out"
  pass "an empty board says so in Decisions, Underway, Landed, and Queued"
}

# The template fails closed on its own, without the build gate: inject a wrong
# schema straight into the shipped template.
test_the_template_fails_closed_on_unreadable_data() {
  local home board out
  home=$(make_home fail-closed)
  board="$home/board.html"
  BOARD_JSON='{"schema":"fm-bearings-board.v0"}' \
    perl -pe 's/^__FM_BEARINGS_BOARD_DATA__$/$ENV{BOARD_JSON}/' \
    "$ROOT/.agents/skills/bearings/assets/board-template.html" > "$board"
  printf '[]\n' > "$home/steps.json"
  out=$(node "$HARNESS" "$board" "$home/steps.json") || fail "the injected board could not be rendered"
  printf '%s' "$out" | jq -e '.error | test("This board could not load") and test("fm-bearings-board.v0")' >/dev/null \
    || fail "the template rendered unreadable data instead of failing closed: $out"
  pass "the template says the board could not load rather than rendering an empty fleet"
}

test_the_inbox_comes_first_in_folding_sections
test_an_inbox_item_shows_its_own_actions_and_value_boxes
test_an_action_carries_its_values_note_and_route
test_an_action_with_an_empty_box_refuses_and_marks_it
test_a_note_alone_is_sent_as_the_captains_words
test_a_decision_card_opens_on_its_recommendation
test_take_all_recommendations_confirms_then_sends_one_answer_per_card
test_take_all_carries_each_cards_typed_note
test_sections_remember_their_fold_per_viewer
test_later_and_the_fleet_read_as_plain_words
test_an_empty_board_says_so_in_each_place
test_the_template_fails_closed_on_unreadable_data

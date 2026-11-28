#!/usr/bin/env bash
# Behavior tests for asks to people outside the fleet (bin/fm-asks.sh): the
# `Asked:` line bin/fm-tasks-axi.sh `asked` records and `update` carries, the
# open-ask list with its age (also as `fm-tasks-axi.sh list --asked`), and the
# settlement each close path runs - done, rm, the prune's removed close, the
# teardown close and a closing captain answer: Nova is told once through the
# fleet-handoff script for Sapna's ask, nothing is sent for Sunita's, an
# envelope Nova already reported needs nothing, and a forced close settles
# nothing. A stub stands in for the fleet-handoff script and logs each call.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-asks)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_DATA_OVERRIDE \
  FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_HANDOFF_CLOSE_REPLY FM_ASKS_TODAY

TODAY=$(date -u +%Y-%m-%d)

make_home() {  # <name>; prints the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # The stub answers `sent <id>` from sent-state/<id> (missing when absent)
  # and `to-nova` with one handed id; every call lands in its log.
  mkdir -p "$home/sent-state"
  cat > "$home/handoff.sh" <<'EOF'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")" && pwd)
{ printf 'call:'; printf ' [%s]' "$@"; printf '\nhome: %s\n' "${FM_HANDOFF_FM_HOME:-}"; } >> "$dir/handoff.log"
case "$1" in
  sent)
    [ -f "$dir/sent-state/$2" ] || { echo "fm-handoff: no handoff $2" >&2; exit 1; }
    printf '%s\tnova\t%s\n---\n' "$2" "$(cat "$dir/sent-state/$2")" ;;
  to-nova) printf 'handed 1795000000-settled\n  file: x\n' ;;
esac
EOF
  chmod +x "$home/handoff.sh"
  : > "$home/handoff.log"
  printf '%s\n' "$home"
}

tasks() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ASKS_HANDOFF="$home/handoff.sh" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

asks() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ASKS_HANDOFF="$home/handoff.sh" "$ROOT/bin/fm-asks.sh" "$@"
}

calls() { grep -c '^call:' "$1/handoff.log"; }

test_asked_line_is_recorded_kept_and_carried() {
  local home out
  home=$(make_home tag)
  tasks "$home" add sap-one "Ask Sapna about the logo" --kind task --due 2026-12-20 >/dev/null || fail "could not add sap-one"
  assert_equals - "$(tasks "$home" asked sap-one)" "an untagged row read as asked"
  out=$(tasks "$home" asked sap-one sapna 1794541457-logo) || fail "asked refused a valid ask: $out"
  assert_equals "sapna $TODAY 1794541457-logo" "$(tasks "$home" asked sap-one)" "the ask was not recorded with today's date"
  # The recorded date stands on a repeat, so the age stays true.
  tasks "$home" update sap-one --body "Ask her.

Asked: sapna 2026-11-01 1794541457-logo" >/dev/null || fail "could not backdate the ask"
  out=$(tasks "$home" asked sap-one sapna 1794541457-logo) || fail "a repeat ask failed: $out"
  assert_contains "$out" "already sapna 2026-11-01" "a repeat ask reset the date"
  # A body rewrite that names no ask keeps it, beside the due date and owner.
  tasks "$home" update sap-one --body "Ask her, nicely." >/dev/null || fail "could not rewrite the body"
  assert_equals "sapna 2026-11-01 1794541457-logo" "$(tasks "$home" asked sap-one)" "update dropped the Asked: line"
  assert_equals 2026-12-20 "$(tasks "$home" due sap-one)" "update dropped the due date beside the ask"
  assert_equals fleet "$(tasks "$home" owner sap-one)" "the ask displaced the owner line"
  local args rc
  for args in "sap-one bob" "sap-one sapna bad!ref" "sap-one sapna a b" "missing-row sunita"; do
    rc=0
    # shellcheck disable=SC2086 # each case is its own argument list
    tasks "$home" asked $args >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "asked $args"
  done
  tasks "$home" asked sap-one - >/dev/null || fail "could not clear the ask"
  assert_equals - "$(tasks "$home" asked sap-one)" "clearing left the ask"
  pass "asked records <person> <date> [<ref>], keeps the first date, survives a body rewrite and refuses bad values"
}

test_list_shows_open_asks_with_age() {
  local home out long
  home=$(make_home list)
  tasks "$home" add sap-old "Ask Sapna about the font" --kind task --body "Asked: sapna 2026-11-10 1790000000-font" >/dev/null
  long=$(printf 'word %.0s' $(seq 1 400))
  tasks "$home" add sun-long "Ask Sunita for the price list" --kind task --body "$long

Asked: sunita 2026-11-20 29" >/dev/null
  tasks "$home" add held-ask "Ask Sapna for the photo" --kind task --body "Asked: sapna 2026-11-25" >/dev/null
  tasks "$home" hold held-ask --kind external --until 2026-12-30 --reason "waiting on Sapna" >/dev/null
  tasks "$home" add closed-ask "Ask Sapna, closed" --kind task --body "Asked: sapna 2026-11-01 1780000000-old" >/dev/null
  FM_HANDOFF_CLOSE_REPLY=skip tasks "$home" "done" closed-ask >/dev/null 2>&1
  tasks "$home" add plain "Plain row" --kind task >/dev/null

  out=$(FM_ASKS_TODAY=2026-11-30 asks "$home" list) || fail "list failed: $out"
  assert_equals "sap-old	sapna	20d	2026-11-10	1790000000-font	Ask Sapna about the font
sun-long	sunita	10d	2026-11-20	29	Ask Sunita for the price list
held-ask	sapna	5d	2026-11-25	-	Ask Sapna for the photo" "$out" "the list is not every open ask, oldest first, with its age"
  out=$(FM_ASKS_TODAY=2026-11-30 tasks "$home" list --asked sunita) || fail "list --asked failed: $out"
  assert_equals "sun-long	sunita	10d	2026-11-20	29	Ask Sunita for the price list" "$out" "list --asked sunita is not Sunita's asks alone"
  out=$(FM_ASKS_TODAY=2026-11-30 tasks "$home" list --asked sapna --json) || fail "list --json failed"
  assert_equals '["sap-old",20,"1790000000-font","held-ask",5,null]' \
    "$(printf '%s' "$out" | jq -c '[.[] | .id, .age_days, .ref]')" "the JSON list lost a field"
  out=$(asks "$(make_home empty)" list)
  assert_equals "no open asks" "$out" "an empty list did not say so"
  pass "list prints every open ask with its age, narrows by person, and reads one cut short in the listing"
}

test_close_tells_nova_once_and_sends_nothing_for_sunita() {
  local home out err
  home=$(make_home close)
  tasks "$home" add sap-one "Ask Sapna about the logo" --kind task --body "Asked: sapna 2026-11-20 1794541457-logo" >/dev/null
  printf 'acknowledged\n' > "$home/sent-state/1794541457-logo"
  out=$(tasks "$home" "done" sap-one --pr https://github.com/o/r/pull/7 --json 2>"$home/err") || fail "done failed"
  printf '%s' "$out" | jq -e . >/dev/null || fail "done --json stdout is no longer plain JSON: $out"
  err=$(cat "$home/err")
  assert_contains "$err" "told Nova on 1795000000-settled (reply to envelope 1794541457-logo)" "the close did not say it told Nova"
  out=$(cat "$home/handoff.log")
  assert_contains "$out" "call: [sent] [1794541457-logo]" "the close did not read the envelope first"
  assert_contains "$out" "call: [to-nova] [Settled: Ask Sapna about the logo] [--kind] [reply] [--reply-to] [1794541457-logo] [--item] [sap-one] [--domain] [sapna] [--ask]" \
    "the settlement is not the skill's reply envelope"
  assert_contains "$out" "PR https://github.com/o/r/pull/7. Settle 1794541457-logo by its state" "the settlement lost the PR or the settle step"
  assert_contains "$out" "home: $home" "the handoff script was not pointed at this home"
  assert_equals 2 "$(calls "$home")" "the close did not make exactly the read and the send"
  # A replayed close tells Nova nothing more.
  tasks "$home" reopen sap-one >/dev/null
  tasks "$home" "done" sap-one >/dev/null 2>"$home/err" || fail "the replayed done failed"
  assert_contains "$(cat "$home/err")" "already settled" "a replayed close did not say it was settled"
  assert_equals 2 "$(calls "$home")" "a replayed close told Nova twice"
  # A reopened row asked again on a new envelope settles that one.
  tasks "$home" reopen sap-one >/dev/null
  tasks "$home" asked sap-one sapna 1794600000-logo-again >/dev/null
  printf 'sent\n' > "$home/sent-state/1794600000-logo-again"
  tasks "$home" "done" sap-one >/dev/null 2>&1 || fail "the re-asked done failed"
  assert_equals 4 "$(calls "$home")" "a new ask on a reopened row was not settled"

  tasks "$home" add sun-one "Ask Sunita for the price list" --kind task --body "Asked: sunita 2026-11-20 29" >/dev/null
  tasks "$home" rm sun-one --reason "Arjun asked her in person" >/dev/null 2>"$home/err" || fail "rm sun-one failed"
  assert_contains "$(cat "$home/err")" "nothing is sent outside the fleet. Strike item 29 on data/sunita-list.md." \
    "the Sunita close did not name the list item"
  assert_equals 4 "$(calls "$home")" "a Sunita close called the fleet-handoff script"
  pass "a close tells Nova once with the skill's reply envelope, a re-ask settles again, and Sunita's sends nothing"
}

test_close_paths_and_their_limits() {
  local home err
  home=$(make_home paths)
  # Nova already reported the envelope: nothing to send.
  tasks "$home" add sap-done "Ask Sapna, answered" --kind task --body "Asked: sapna 2026-11-20 1794000000-a" >/dev/null
  printf 'replied\n' > "$home/sent-state/1794000000-a"
  tasks "$home" "done" sap-done >/dev/null 2>"$home/err" || fail "done sap-done failed"
  assert_contains "$(cat "$home/err")" "Nova already reported envelope 1794000000-a, so nothing was sent" "a reported envelope was settled again"
  assert_equals 1 "$(calls "$home")" "a reported envelope got a send"
  # An envelope the script cannot find, or no envelope id: the close lands and warns.
  tasks "$home" add sap-lost "Ask Sapna, lost" --kind task --body "Asked: sapna 2026-11-20 1794000000-gone" >/dev/null
  tasks "$home" "done" sap-lost >/dev/null 2>"$home/err" || fail "a failed settlement changed the close's status"
  err=$(cat "$home/err")
  assert_contains "$err" "envelope 1794000000-gone could not be read, so Nova was not told" "a missing envelope did not warn"
  assert_contains "$err" "its ask was not settled" "the wrapper did not flag the unsettled ask"
  tasks "$home" add sap-noid "Ask Sapna, no envelope" --kind task --body "Asked: sapna 2026-11-20" >/dev/null
  tasks "$home" "done" sap-noid >/dev/null 2>"$home/err" || fail "done sap-noid failed"
  assert_contains "$(cat "$home/err")" "has no envelope id" "an ask with no envelope did not warn"
  # A forced close settles nothing.
  tasks "$home" add sap-skip "Ask Sapna, forced" --kind task --body "Asked: sapna 2026-11-20 1794000000-s" >/dev/null
  printf 'sent\n' > "$home/sent-state/1794000000-s"
  FM_HANDOFF_CLOSE_REPLY=skip tasks "$home" "done" sap-skip >/dev/null 2>&1 || fail "done sap-skip failed"
  assert_equals 2 "$(calls "$home")" "a skipped close settled the ask"
  # The prune's drop settles as removed, with its note as the reason.
  tasks "$home" add sap-prune "Ask Sapna, pruned" --kind task --body "Asked: sapna 2026-11-20 1794000000-p" >/dev/null
  printf 'sent\n' > "$home/sent-state/1794000000-p"
  FM_HANDOFF_CLOSE_REPLY=removed tasks "$home" "done" sap-prune --note "dropped by the prune" >/dev/null 2>&1
  assert_contains "$(cat "$home/handoff.log")" "off its backlog on $TODAY without doing it; reason: dropped by the prune" \
    "the prune's close did not settle as removed"
  # The teardown close settles the row it closed.
  tasks "$home" add sap-tear "Ask Sapna, shipped" --kind task --body "Asked: sapna 2026-11-20 1794000000-t" >/dev/null
  printf 'sent\n' > "$home/sent-state/1794000000-t"
  tasks "$home" "done" sap-tear --pr https://github.com/o/r/pull/9 >/dev/null 2>&1
  : > "$home/handoff.log"
  tasks "$home" reopen sap-tear >/dev/null
  rm -f "$home/state/asks/sap-tear.settled"
  FM_HOME="$home" FM_ASKS_HANDOFF="$home/handoff.sh" bash -c '
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_done "$2/data" sap-tear --pr https://github.com/o/r/pull/9 >/dev/null
    fm_backlog_close_reply "$2/state" "$2/data" sap-tear --pr https://github.com/o/r/pull/9' _ "$ROOT" "$home" \
    2>"$home/err" || fail "the teardown close failed"
  assert_contains "$(cat "$home/err")" "told Nova on 1795000000-settled" "the teardown close did not settle the ask"
  assert_contains "$(cat "$home/handoff.log")" "PR https://github.com/o/r/pull/9" "the teardown settlement lost the PR"
  pass "a reported envelope needs nothing, a failed settlement only warns, and skip, prune and teardown closes settle as they should"
}

test_captain_answer_settles_the_ask() {
  local home
  home=$(make_home answer)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold sap-call --title "Ask Sapna or add it now" --reason "ask her or add it" >/dev/null \
    || fail "could not hold the call"
  tasks "$home" asked sap-call sapna 1794541457-device >/dev/null || fail "could not tag the call"
  printf 'sent\n' > "$home/sent-state/1794541457-device"
  printf 'Add now, no ask needed.\n' > "$home/answer.txt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ASKS_HANDOFF="$home/handoff.sh" "$ROOT/bin/fm-captain-hold.sh" answer sap-call --decision-file "$home/answer.txt" \
    >/dev/null 2>"$home/err" || fail "the answer was refused: $(cat "$home/err")"
  assert_contains "$(cat "$home/handoff.log")" "note: the captain answered it: Add now, no ask needed.. Settle 1794541457-device" \
    "a closing answer did not tell Nova the captain's words"
  pass "a closing captain answer settles the call's ask with his first line"
}

fm_test_run \
  test_asked_line_is_recorded_kept_and_carried \
  test_list_shows_open_asks_with_age \
  test_close_tells_nova_once_and_sends_nothing_for_sunita \
  test_close_paths_and_their_limits \
  test_captain_answer_settles_the_ask

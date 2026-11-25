#!/usr/bin/env bash
# bin/fm-later-rulings.sh: the captain rulings dated on or after a ship's
# recorded approval, read from fixture data/captain.md and
# data/captain-shared.md files and from backlog rows that bin/fm-captain-hold.sh
# itself holds and answers. The listing is advisory, so every case that finds
# nothing or cannot read still exits 0.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-later-rulings)
LATER="$ROOT/bin/fm-later-rulings.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

in_home() {  # <home> <command> [args...]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

# Hold <id> for the captain, then record <words> as his releasing answer, the
# way an approval of held work is recorded.
approve() {  # <home> <id> <words>
  local home=$1 id=$2
  printf '%s\n' "$3" > "$home/answer.txt"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id" --title "Land the approved text" \
    --reason "approve the drafted text" --kind reversible --batch "board:$id" >/dev/null 2>&1 \
    || fail "could not hold $id"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" \
    --release >/dev/null 2>&1 || fail "could not release $id"
}

write_captain_files() {  # <home>
  cat > "$1/data/captain.md" <<'EOF'
# Captain
<!-- memory tiers: see the stow skill -->

- Older rule (Arjun 2026-11-12): ship drafts as approved.
- Codex is the reviewer only (Arjun 2026-11-21, agent roles Q4): drop the second-builder role.
- Same-day rule (Arjun 2026-11-20 board): keep the brief short.
- Relayed rule (Arjun 2026-11-01; relayed here 2026-11-22): an older ruling that moved here later.
- Wrapped rule (Arjun 2026-11-02):
  amended on 2026-11-23 with a second line.
- Short-date rule (Arjun 11-24): a short date alone is not read.
EOF
  cat > "$1/data/captain-shared.md" <<'EOF'
# Shared captain preferences

- Shared rule (Arjun 2026-11-24): every home keeps this.
- Shared old rule (Arjun 2026-10-01): an old shared ruling.
EOF
}

test_rulings_after_the_recorded_approval_are_listed() {
  local home out rc
  home=$(make_home listed)
  write_captain_files "$home"
  approve "$home" ship-text "Arjun 2026-11-10 on the board: approve the draft."
  # A later re-hold and answer is the newest record, so its date is the approval.
  approve "$home" ship-text "Arjun 2026-11-20 on the board: ship the arjun.md line as drafted."
  out=$(in_home "$home" "$LATER" ship-text 2>&1)
  rc=$?
  expect_code 0 "$rc" "the listing failed: $out"
  assert_contains "$out" "later-rulings: ship-text was approved 2026-11-20 (the newest captain-hold resolution on its backlog row); 5 captain ruling(s)" \
    "the header did not name the newest approval and the count"$'\n'"$out"
  assert_contains "$out" "data/captain.md:5 2026-11-21 - Codex is the reviewer only" \
    "a ruling after the approval was not listed"$'\n'"$out"
  assert_contains "$out" "data/captain.md:6 2026-11-20 - Same-day rule" \
    "a ruling dated the approval day was not listed"$'\n'"$out"
  assert_contains "$out" "data/captain.md:7 2026-11-22 - Relayed rule" \
    "an item did not count from its latest date"$'\n'"$out"
  assert_contains "$out" "data/captain.md:8 2026-11-23 - Wrapped rule (Arjun 2026-11-02): amended on 2026-11-23" \
    "a continuation line was not read with its item"$'\n'"$out"
  assert_contains "$out" "data/captain-shared.md:3 2026-11-24 - Shared rule" \
    "a ruling in data/captain-shared.md was not listed"$'\n'"$out"
  case "$out" in
    *"Older rule"*|*"Short-date rule"*|*"Shared old rule"*|*"memory tiers"*)
      fail "an item dated before the approval, or with no full date, was listed"$'\n'"$out" ;;
  esac
  pass "rulings on or after the newest recorded approval are listed from both captain files, and older or undated ones are not"
}

test_since_overrides_the_backlog_row() {
  local home out
  home=$(make_home since)
  write_captain_files "$home"
  # No backlog row exists, so only --since can date the approval.
  out=$(in_home "$home" "$LATER" ship-elsewhere --since 2026-11-23 2>&1)
  expect_code 0 "$?" "the --since listing failed: $out"
  assert_contains "$out" "later-rulings: ship-elsewhere was approved 2026-11-23 (--since); 2 captain ruling(s)" \
    "--since did not set the approval date"$'\n'"$out"
  assert_contains "$out" "data/captain.md:8 2026-11-23" "the wrapped rule was not listed"$'\n'"$out"
  assert_contains "$out" "data/captain-shared.md:3 2026-11-24" "the shared rule was not listed"$'\n'"$out"
  pass "--since dates an approval recorded somewhere other than the backlog row"
}

test_nothing_to_list_says_so_once_and_found_only_is_silent() {
  local home out rc
  home=$(make_home empty)
  out=$(in_home "$home" "$LATER" ship-text 2>&1)
  rc=$?
  expect_code 0 "$rc" "a home with no captain file failed"
  assert_equals "later-rulings: no data/captain.md or data/captain-shared.md in this home" "$out" \
    "a home with no captain file did not say so in one line"

  write_captain_files "$home"
  out=$(in_home "$home" "$LATER" missing-row 2>&1)
  expect_code 0 "$?" "an unreadable row failed"
  assert_equals "later-rulings: could not read the backlog row of missing-row; pass --since YYYY-MM-DD to check its approval" "$out" \
    "an unreadable backlog row did not say so in one line"

  in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add plain-ship "Unheld ship" --kind ship >/dev/null 2>&1 \
    || fail "could not add a plain row"
  out=$(in_home "$home" "$LATER" plain-ship 2>&1)
  expect_code 0 "$?" "a row with no approval failed"
  assert_equals "later-rulings: plain-ship records no dated captain approval; pass --since YYYY-MM-DD to check it" "$out" \
    "a row with no captain approval did not say so in one line"

  approve "$home" undated-ship "Firstmate decided: ship it."
  out=$(in_home "$home" "$LATER" undated-ship 2>&1)
  assert_equals "later-rulings: undated-ship records no dated captain approval; pass --since YYYY-MM-DD to check it" "$out" \
    "a decision text with no date was read as an approval"

  out=$(in_home "$home" "$LATER" plain-ship --since 2026-11-30 2>&1)
  assert_equals "later-rulings: no captain ruling dated on or after plain-ship's approval 2026-11-30" "$out" \
    "an approval with no later ruling did not say so in one line"

  for args in "plain-ship" "missing-row" "plain-ship --since 2026-11-30"; do
    # shellcheck disable=SC2086 # Word splitting builds each argument set.
    out=$(in_home "$home" "$LATER" $args --found-only 2>&1)
    expect_code 0 "$?" "--found-only failed for: $args"
    [ -z "$out" ] || fail "--found-only printed a line when nothing was found ($args): $out"
  done
  pass "each nothing-found case prints one line and exits 0, and --found-only prints nothing"
}

test_malformed_arguments_exit_2() {
  local home args
  home=$(make_home args)
  for args in "" "--since 2026-1-5 ship" "../evil" "a b" "ship --bogus" "ship --since"; do
    # shellcheck disable=SC2086 # Word splitting builds each refused argument set.
    if in_home "$home" "$LATER" $args >/dev/null 2>&1; then
      fail "a malformed argument set was accepted: '$args'"
    fi
    # shellcheck disable=SC2086
    in_home "$home" "$LATER" $args >/dev/null 2>&1
    expect_code 2 "$?" "a malformed argument set did not exit 2: '$args'"
  done
  pass "a malformed argument exits 2"
}

test_rulings_after_the_recorded_approval_are_listed
test_since_overrides_the_backlog_row
test_nothing_to_list_says_so_once_and_found_only_is_silent
test_malformed_arguments_exit_2

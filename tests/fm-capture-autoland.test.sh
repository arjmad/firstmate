#!/usr/bin/env bash
# Tests for bin/fm-capture-autoland.sh and its bin/fm-inbox.sh hook: an
# opted-in green skill-capture note is landed through bin/fm-capture-land.sh and
# acknowledged with no wake, while every other note, and every failed land,
# still wakes firstmate. A copied bin/ swaps fm-capture-land.sh for a stub that
# logs its arguments and exits with a chosen code.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capture-autoland)
URL=https://github.com/arjmad/nova/pull/325
SHA=0123456789abcdef0123456789abcdef01234567

# new_case: a code root with a stubbed fm-capture-land.sh and a home that opts
# [nova-skills] in. Echoes the case directory.
new_case() {
  local c
  c=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$c/home/state" "$c/home/data" "$c/home/config"
  cp -R "$ROOT/bin" "$c/bin"
  cat > "$c/bin/fm-capture-land.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> '$c/land.log'
echo "stub land output"
exit "\$(cat '$c/land-rc' 2>/dev/null || echo 0)"
STUB
  chmod +x "$c/bin/fm-capture-land.sh"
  printf '# capture tags that land automatically\n[nova-skills]\n' > "$c/home/config/capture-autoland"
  printf '%s\n' "$c"
}

green_body() {  # <case> [land-path]
  local land=${2:-$1/bin/fm-capture-land.sh}
  printf '[nova-skills] skill capture green: 2 path(s) in %s at %s\nLand it: %s %s --head %s' \
    "$URL" "$SHA" "$land" "$URL" "$SHA"
}

note() {  # <case> <body>
  printf '%s' "$2" | FM_HOME="$1/home" "$1/bin/fm-inbox.sh" note -
}

wakes() {
  if [ -f "$1/home/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/home/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

note_id() { sed -n 's/^queued //p' <<< "$1" | head -n 1; }

wait_settled() {  # <case> <id>: until the lander acknowledged or announced
  local i
  for i in $(seq 1 100); do
    [ -f "$1/home/state/inbox/handled/$2.note" ] && return 0
    [ "$(wakes "$1")" != 0 ] && return 0
    sleep 0.1
  done
  return 1
}

test_green_note_lands_without_a_wake() {
  local c out id
  c=$(new_case)
  out=$(note "$c" "$(green_body "$c")")
  assert_contains "$out" "landing automatically" "the note is handed to the lander"
  id=$(note_id "$out")
  wait_settled "$c" "$id" || fail "the lander never settled note $id"
  assert_equals "$URL --head $SHA" "$(cat "$c/land.log")" "the lander runs fm-capture-land.sh with the note's arguments"
  [ -f "$c/home/state/inbox/handled/$id.note" ] || fail "a landed note is acknowledged"
  assert_equals 0 "$(wakes "$c")" "a landed note never wakes firstmate"
}

test_failed_land_wakes_with_the_reason() {
  local c out id
  c=$(new_case)
  echo 1 > "$c/land-rc"
  out=$(note "$c" "$(green_body "$c")")
  id=$(note_id "$out")
  wait_settled "$c" "$id" || fail "the lander never settled note $id"
  [ -f "$c/home/state/inbox/$id.note" ] || fail "a failed land leaves the note pending"
  assert_equals 1 "$(wakes "$c")" "a failed land wakes firstmate once"
  assert_contains "$(cat "$c/home/state/.wake-queue")" "capture autoland failed (exit 1): stub land output" \
    "the wake names the exit and the last output line"
}

test_queue_exit_still_wakes() {
  local c out id
  c=$(new_case)
  echo 3 > "$c/land-rc"
  out=$(note "$c" "$(green_body "$c")")
  id=$(note_id "$out")
  wait_settled "$c" "$id" || fail "the lander never settled note $id"
  assert_contains "$(cat "$c/home/state/.wake-queue")" "exit 3" "an unfinished land (exit 3) still reaches firstmate"
}

# Notes that are not exactly an opted-in green capture note wake firstmate at
# once and never reach the lander.
assert_announced_unlanded() {  # <case> <body> <what>
  local out
  out=$(note "$1" "$2")
  assert_contains "$out" "firstmate will pick this up" "$3: announced"
  sleep 0.3
  [ ! -f "$1/land.log" ] || fail "$3: the lander must not run"
}

test_non_matching_notes_are_announced() {
  local c
  c=$(new_case)
  assert_announced_unlanded "$c" "[nova-skills] skill capture: 2 path(s) in $URL; merge when ./check.sh passes; gate red at $SHA: check: x" "red note"
  c=$(new_case)
  assert_announced_unlanded "$c" "$(green_body "$c" | sed 's/^\[nova-skills\]/[cade-skills]/')" "tag not opted in"
  c=$(new_case)
  rm "$c/home/config/capture-autoland"
  assert_announced_unlanded "$c" "$(green_body "$c")" "feature off"
  c=$(new_case)
  assert_announced_unlanded "$c" "$(green_body "$c" "$TMP_ROOT/elsewhere/fm-capture-land.sh")" "another fm-capture-land.sh"
  c=$(new_case)
  assert_announced_unlanded "$c" "$(green_body "$c" | sed "2s/--head $SHA/--head 1111111111111111111111111111111111111111/")" "Land it names another head"
  c=$(new_case)
  assert_announced_unlanded "$c" "$(green_body "$c")
extra line" "an extra line"
  c=$(new_case)
  assert_announced_unlanded "$c" "$(green_body "$c") --force" "an extra argument"
}

test_match_prints_url_and_head() {
  local c f
  c=$(new_case)
  f="$c/x.note"
  printf 'id=x\nsource=text\n--\n%s\n' "$(green_body "$c")" > "$f"
  assert_equals "$URL $SHA" "$(FM_HOME="$c/home" "$c/bin/fm-capture-autoland.sh" match "$f")" "match prints the PR and head"
}

test_take_is_idempotent() {
  local c id
  c=$(new_case)
  id=1-manual
  mkdir -p "$c/home/state/inbox/autoland"
  printf 'id=%s\nannounce_marker=1\n--\n%s\n' "$id" "$(green_body "$c")" > "$c/home/state/inbox/$id.note"
  date > "$c/home/state/inbox/autoland/$id.taken"
  FM_HOME="$c/home" "$c/bin/fm-capture-autoland.sh" take "$id" || fail "a taken note stays taken"
  sleep 0.3
  [ ! -f "$c/land.log" ] || fail "a second take starts no second lander"
}

test_green_note_lands_without_a_wake
pass "a green capture note lands and is acknowledged with no wake"
test_failed_land_wakes_with_the_reason
pass "a failed land wakes firstmate with its exit and last line"
test_queue_exit_still_wakes
pass "an unfinished land still reaches firstmate"
test_non_matching_notes_are_announced
pass "every note that is not exactly an opted-in green capture note is announced at once"
test_match_prints_url_and_head
pass "match prints the PR URL and head"
test_take_is_idempotent
pass "take starts at most one lander per note"

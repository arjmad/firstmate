#!/usr/bin/env bash
# Behavior tests for placement by rule in the spawn path: when this home's
# config/intake-spill declares a `first` rule for a project, bin/fm-spawn.sh
# refuses a fresh local ship or scout while the rule's remote secondmate is
# running with a free slot, and on a fallback launches it here with the reason
# in the task record (bin/fm-intake-spill.sh owns the rule and its probe).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin and fake tmux and treehouse binaries that log every call. The
# remote secondmate is reached through the real bin/fm-on.sh route with a
# stubbed ssh (the FM_SSH_BIN seam) that decodes the remote command and answers
# its endpoint state and lane capacity document, so no case reaches a real
# host. A refused spawn is judged by what it left behind - no task record, no
# rendered launch brief, no endpoint, no worktree - never by wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-placement)

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Change the project for $2.

## Firstmate spec
Exercise placement by rule.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# make_case <name> <task-id...>: a home whose first rule sends `project` to the
# remote secondmate faf, a project clone with an origin, and the fake terminal,
# worktree tool, and ssh.
make_case() {
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  : > "$case_dir/ssh.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name= previous=
    for arg in "$@"; do [ "$previous" = -n ] && name=$arg; previous=$arg; done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] && exit 0
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
cmd=$(printf '%s' "$last" | { base64 -d 2>/dev/null || base64 -D; } | tr '\0' ' ')
printf '%s\n' "$cmd" >> "$FM_FAKE_SSH_LOG"
[ "${FM_FAKE_SSH_RC:-0}" = 0 ] || exit "$FM_FAKE_SSH_RC"
case "$cmd" in
  fm-remote-secondmate-control.sh*) printf 'alive\n' ;;
  fm-capacity.sh*) printf '{"schema":"fm-lane-capacity.v1","lanes":{"count":1},"cap":{"target":null,"status":"none","mode":"auto"},"budget":{"by":{"memory":%s,"cpu":0,"disk":9,"ceiling":null}},"gates":[]}\n' "${FM_FAKE_MEMORY_SLOTS:-2}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/fake-ssh"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other"
  fm_git_add_origin "$case_dir/other" "$case_dir/other.origin.git"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' "- faf - Runs firstmate work on the second machine. (host: faf-ssh; root: /srv/firstmate; home: /srv/faf; scope: firstmate work; projects: project; added 2026-11-10)" \
    > "$home/data/secondmates.md"
  printf '%s\n' 'first faf project' > "$home/config/intake-spill"
  for id in "$@"; do write_brief "$home" "$id"; done
  printf '%s\n' "$case_dir"
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <pane-path> <args...>
  local case_dir=$1 pane=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE="$case_dir" FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_SSH_BIN="$case_dir/fakebin/fake-ssh" FM_FAKE_SSH_LOG="$case_dir/ssh.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [extra-args...]
  local case_dir=$1 id=$2
  shift 2
  run_spawn "$case_dir" "$(new_worktree "$case_dir" "$id")" "$id" "$case_dir/project" --mode no-mistakes --yolo off "$@"
}

assert_nothing_created() {  # <case-dir> <id>
  assert_absent "$1/home/state/$2.meta" "a refused spawn published a task record for $2"
  assert_absent "$1/home/data/$2/launch-brief.md" "a refused spawn rendered a launch brief for $2"
  [ ! -s "$1/calls.log" ] || fail "a refused spawn touched the terminal or worktree pool for $2: $(cat "$1/calls.log")"
}

# --- cases ------------------------------------------------------------------

test_free_secondmate_refuses_the_local_spawn() {
  local case_dir out rc=0
  case_dir=$(make_case free task-a)
  out=$(spawn_ship "$case_dir" task-a) || rc=$?
  expect_code 1 "$rc" "a spawn the rule sends to a free secondmate was not refused: $out"
  assert_contains "$out" "sends project work to secondmate faf first" "the refusal names the rule's secondmate"
  assert_contains "$out" "faf is running and has 2 free slot(s)" "the refusal names why the secondmate takes it"
  assert_contains "$out" "--placement-override" "the refusal names the captain's redirect"
  assert_contains "$(cat "$case_dir/ssh.log")" "fm-capacity.sh --json" "the spawn probed the remote lane capacity"
  assert_nothing_created "$case_dir" task-a
  pass "a fresh spawn the first rule sends to a running secondmate with a free slot is refused and leaves nothing"
}

test_fallback_launches_here_and_records_the_reason() {
  local case_dir out rc=0
  case_dir=$(make_case fallback task-a task-b)
  out=$(FM_FAKE_SSH_RC=255 spawn_ship "$case_dir" task-a) || rc=$?
  expect_code 0 "$rc" "a fallback spawn was refused: $out"
  assert_contains "$out" "spawned task-a" "a fallback spawn did not launch"
  assert_contains "$out" "placement: project work falls back to this home: faf does not answer on its host faf-ssh" "the fallback is announced"
  assert_contains "$out" "placement-notice: first fallback in this home - tell the captain once" "the first fallback asks to tell the captain"
  assert_grep "placement=fallback" "$case_dir/home/state/task-a.meta" "the task record marks the fallback"
  assert_grep "placement_reason=faf does not answer on its host faf-ssh" "$case_dir/home/state/task-a.meta" "the task record keeps the reason"
  rc=0
  out=$(FM_FAKE_MEMORY_SLOTS=0 spawn_ship "$case_dir" task-b) || rc=$?
  expect_code 0 "$rc" "a second fallback spawn was refused: $out"
  assert_contains "$out" "faf has no free slot" "a full secondmate falls back with its reason"
  assert_not_contains "$out" "placement-notice:" "a later fallback does not tell the captain again"
  pass "a fallback launches here, records the reason on the task, and tells the captain only once"
}

test_override_skips_the_probe_and_is_recorded() {
  local case_dir out rc=0
  case_dir=$(make_case override task-a)
  out=$(spawn_ship "$case_dir" task-a --placement-override "captain asked for this home") || rc=$?
  expect_code 0 "$rc" "an overridden spawn was refused: $out"
  assert_contains "$out" "spawned task-a" "an overridden spawn did not launch"
  [ ! -s "$case_dir/ssh.log" ] || fail "an overridden spawn still probed the remote host: $(cat "$case_dir/ssh.log")"
  assert_grep "placement_override=captain asked for this home" "$case_dir/home/state/task-a.meta" "the task record keeps the redirect"
  pass "--placement-override records the captain's redirect and skips the probe"
}

test_project_outside_the_rule_is_untouched() {
  local case_dir out rc=0 wt
  case_dir=$(make_case outside task-a)
  git -C "$case_dir/other" worktree add --quiet -b wt-task-a "$case_dir/wt-other"
  wt="$case_dir/wt-other"
  out=$(run_spawn "$case_dir" "$wt" task-a "$case_dir/other" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a project outside the rule was refused: $out"
  [ ! -s "$case_dir/ssh.log" ] || fail "a project outside the rule probed the remote host"
  assert_no_regex "^placement(_reason|_override)?=" "$case_dir/home/state/task-a.meta" "a project outside the rule records no placement"
  pass "a project the rule does not name spawns exactly as before"
}

test_unreadable_declaration_refuses() {
  local case_dir out rc=0
  case_dir=$(make_case unreadable task-a)
  printf '%s\n' 'first faf' > "$case_dir/home/config/intake-spill"
  out=$(spawn_ship "$case_dir" task-a) || rc=$?
  expect_code 1 "$rc" "an unreadable placement rule did not refuse: $out"
  assert_contains "$out" "placement rule cannot be read" "the refusal names the unreadable rule"
  assert_nothing_created "$case_dir" task-a
  pass "an unreadable placement rule refuses the spawn rather than guessing"
}

test_free_secondmate_refuses_the_local_spawn
test_fallback_launches_here_and_records_the_reason
test_override_skips_the_probe_and_is_recorded
test_project_outside_the_rule_is_untouched
test_unreadable_declaration_refuses

printf '# all fm-spawn-placement tests passed\n'

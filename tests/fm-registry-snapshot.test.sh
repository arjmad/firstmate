#!/usr/bin/env bash
# Behavior tests for the strict Registry-safe projection over fm-fleet-snapshot.sh.
# Covers the exact schema, zero-network default, comprehensive leak sentinels,
# aggregate accuracy, posture allowlists, unavailable-state degradation, unchanged
# bearings compatibility, and shell/static checks.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-registry-snapshot.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-registry-snapshot)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

make_fakebin() {  # <dir>
  local fb tool
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "$*" in *fm-dead*) exit 1 ;; *) printf '%%1\n' ;; esac
    ;;
  capture-pane) printf 'working locally\n> \n' ;;
esac
exit 0
SH
  for tool in gh gh-axi curl wget ssh scp nc; do
    cat > "$fb/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$NET_LOG"
exit 97
SH
  done
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi" \
    "$fb/curl" "$fb/wget" "$fb/ssh" "$fb/scp" "$fb/nc"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

make_secondmate_home() {  # <id> <name>
  local id=$1 mate=$TMP_ROOT/$2
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '# Fixture firstmate home\n' > "$mate/AGENTS.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] mate-active - Active secondmate fixture task (repo: alpha) (kind: ship) (since 2026-07-24)

## Queued
- [ ] mate-queued - Queued secondmate fixture task (repo: alpha) (kind: ship)

## Done
- [x] mate-done - Completed secondmate fixture task (repo: alpha) (kind: ship) (done 2026-07-24)
EOF
  mkdir -p "$mate/projects/mate-active"
  fm_write_meta "$mate/state/mate-active.meta" \
    'window=firstmate:fm-mate-active' \
    "worktree=$mate/projects/mate-active" \
    'project=alpha' \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes'
  printf 'working: secondmate fixture activity\n' > "$mate/state/mate-active.status"
  printf '%s\n' "$mate"
}

write_complete_fixture() {  # <home>
  local home=$1 mate
  mate=$(make_secondmate_home mate-one "$(basename "$home")-mate")
  cat > "$home/data/projects.md" <<'EOF'
- alpha [no-mistakes] - first fixture project (added 2026-07-24)
- beta [local-only +yolo] - second fixture project (added 2026-07-24)
EOF
  printf -- '- mate-one - fixture domain (home: %s; scope: fixture work; projects: alpha; added 2026-07-24)\n' \
    "$mate" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-one - Active fixture task (repo: alpha) (kind: ship) (since 2026-07-24)

## Queued
- [ ] queued-one - Queued fixture task (repo: beta) (kind: ship)

## Done
- [x] done-one - Completed fixture task (repo: alpha) (kind: ship) (done 2026-07-24)
EOF
  mkdir -p "$home/projects/dead-work"
  fm_write_meta "$home/state/active-one.meta" \
    'window=firstmate:fm-dead' \
    "worktree=$home/projects/dead-work" \
    'project=alpha' \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes'
  printf 'working: local fixture activity\n' > "$home/state/active-one.status"
  printf 'FMX_PAIRING_TOKEN=fixture-token-value\n' > "$home/.env"
}

run_snapshot() {  # <home> <fakebin> [backend]
  local home=$1 fakebin=$2 backend=${3:-tmux}
  : > "$home/net.log"
  PATH="$fakebin:$PATH" \
    NET_LOG="$home/net.log" \
    FM_HOME="$home" \
    FM_BACKEND="$backend" \
    TMUX='' HERDR_ENV=0 CMUX_WORKSPACE_ID='' __CFBundleIdentifier='' \
    FM_REGISTRY_SNAPSHOT_NOW=2026-07-24T12:34:56Z \
    "$SNAPSHOT" --json
}

run_bearings() {  # <home> <fakebin>
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" \
    NET_LOG="$home/net.log" \
    FM_HOME="$home" \
    TMUX='' HERDR_ENV=0 CMUX_WORKSPACE_ID='' __CFBundleIdentifier='' \
    FM_BEARINGS_NOW=2026-07-24T12:34:56Z \
    "$BEARINGS" --json
}

test_schema_exact_keys_and_types() {
  local home fakebin out out_again help
  home=$(make_home schema)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "registry snapshot failed for schema fixture"

  printf '%s' "$out" | jq -e '
    (keys | sort) == ["counts","generated","posture","schema","status","unavailable_fields"] and
    .schema == "fm-registry-snapshot.v1" and
    (.generated | type) == "string" and
    (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.status == "available" or .status == "degraded" or .status == "unavailable") and
    (.unavailable_fields | type) == "array" and all(.unavailable_fields[]; type == "string") and
    (.posture | keys | sort) == ["delivery_modes","runtime_backend","source_revision","verified_adapters","x_mode_enabled"] and
    (.posture.runtime_backend | keys | sort) == ["source","status","value"] and
    (.posture.verified_adapters | keys | sort) == ["status","values"] and
    (.posture.delivery_modes | keys | sort) == ["status","values"] and
    (.posture.x_mode_enabled | keys | sort) == ["status","value"] and
    (.posture.source_revision | keys | sort) == ["status","value"] and
    (.counts | keys | sort) == ["active_tasks","completed_tasks","queued_tasks","registered_projects","registered_secondmates","unhealthy_endpoints"] and
    all(.counts[]; (keys | sort) == ["status","value"]) and
    all(.counts[]; (.status == "available" or .status == "unavailable")) and
    all(.counts[]; (.value == null or ((.value | type) == "number" and .value >= 0 and (.value | floor) == .value)))
  ' >/dev/null || fail "registry snapshot schema or field types drifted"
  out_again=$(run_snapshot "$home" "$fakebin") || fail "repeat registry snapshot failed"
  [ "$out" = "$out_again" ] || fail "fixed local registry snapshot was not deterministic"
  help=$("$SNAPSHOT" --help) || fail "registry snapshot help failed"
  assert_contains "$help" 'fm-registry-snapshot.v1' "registry snapshot help omitted the schema identifier"
  assert_contains "$help" 'local-only' "registry snapshot help omitted the local-only guarantee"
  pass "registry snapshot has exact versioned keys and types with deterministic output"
}

test_local_mode_makes_no_network_calls() {
  local home fakebin
  home=$(make_home no-network)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  run_snapshot "$home" "$fakebin" >/dev/null || fail "local registry snapshot failed"
  [ ! -s "$home/net.log" ] || fail "local registry snapshot invoked a network or GitHub tool"
  pass "registry snapshot performs zero network and GitHub calls"
}

test_leak_sentinels_never_reach_serialized_output() {
  local home fakebin path_sentinel out sentinel
  home=$(make_home leak-sentinel)
  fakebin=$(make_fakebin "$home")
  path_sentinel='LEAK_PATH_FRAGMENT_4f6f89'
  mkdir -p "$home/projects/$path_sentinel"
  cat > "$home/data/projects.md" <<'EOF'
- LEAK_PROJECT_NAME_2cb735 [direct-PR] - private project description (added 2026-07-24)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] leak-task - LEAK_TASK_TITLE_936e11 (repo: LEAK_PROJECT_NAME_2cb735) (kind: ship) (since 2026-07-24)

## Queued
- [ ] leak-decision - LEAK_DECISION_TEXT_54f903 (repo: LEAK_PROJECT_NAME_2cb735) (kind: captain) (hold: LEAK_HOLD_REASON_9a448c) (hold-kind: captain)

## Done
- [x] leak-done - LEAK_LANDED_DESCRIPTION_b4a8d2 (repo: LEAK_PROJECT_NAME_2cb735) (kind: ship) (done 2026-07-24)
EOF
  fm_write_meta "$home/state/leak-task.meta" \
    'window=firstmate:fm-dead' \
    "worktree=$home/projects/$path_sentinel" \
    'project=LEAK_PROJECT_NAME_2cb735' \
    'harness=codex' \
    'kind=ship' \
    'mode=direct-PR'
  cat > "$home/state/leak-task.status" <<'EOF'
working: LEAK_STATUS_PROSE_025d6a
needs-decision [key=leak]: LEAK_DECISION_TEXT_54f903
EOF
  cat > "$home/.env" <<'EOF'
FMX_PAIRING_TOKEN=ghp_LEAK_TOKEN_SHAPED_7c2a9e1234567890
EOF

  out=$(run_snapshot "$home" "$fakebin") || fail "registry snapshot failed for leak fixture"
  for sentinel in \
    LEAK_TASK_TITLE_936e11 \
    LEAK_STATUS_PROSE_025d6a \
    LEAK_DECISION_TEXT_54f903 \
    LEAK_HOLD_REASON_9a448c \
    LEAK_LANDED_DESCRIPTION_b4a8d2 \
    LEAK_PROJECT_NAME_2cb735 \
    "$path_sentinel" \
    ghp_LEAK_TOKEN_SHAPED_7c2a9e1234567890; do
    assert_not_contains "$out" "$sentinel" "registry-safe output leaked sentinel $sentinel"
  done
  pass "registry snapshot excludes all task, decision, path, project, and token sentinels"
}

test_aggregate_counts_match_complete_fixture() {
  local home fakebin out
  home=$(make_home aggregates)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "registry snapshot failed for aggregate fixture"

  printf '%s' "$out" | jq -e '
    .counts.registered_projects == {value:2,status:"available"} and
    .counts.registered_secondmates == {value:1,status:"available"} and
    .counts.active_tasks == {value:2,status:"available"} and
    .counts.queued_tasks == {value:2,status:"available"} and
    .counts.completed_tasks == {value:2,status:"available"} and
    .counts.unhealthy_endpoints == {value:1,status:"available"}
  ' >/dev/null || fail "registry-safe aggregate counts were incorrect"
  pass "registry snapshot reports correct active, queued, completed, project, secondmate, and endpoint counts"
}

test_posture_values_stay_inside_allowlists() {
  local home fakebin out
  home=$(make_home posture)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin" cmux) || fail "registry snapshot failed for posture fixture"

  printf '%s' "$out" | jq -e '
    .posture.runtime_backend == {value:"cmux",source:"configured",status:"available"} and
    .posture.verified_adapters == {values:["claude","codex","grok","opencode","pi"],status:"available"} and
    .posture.delivery_modes == {values:["direct-PR","local-only","no-mistakes"],status:"available"} and
    .posture.x_mode_enabled == {value:true,status:"available"} and
    (.posture.source_revision.status == "available") and
    (.posture.source_revision.value | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
    (.posture.runtime_backend.value | IN("tmux","herdr","zellij","orca","cmux","unknown")) and
    (.posture.runtime_backend.source | IN("configured","auto","fallback","unknown"))
  ' >/dev/null || fail "registry posture escaped its documented allowlists"
  pass "registry snapshot posture fields use only verified classes and safe values"
}

test_missing_unreadable_and_malformed_inputs_degrade_without_leaking() {
  local home fakebin out malformed
  home=$(make_home unavailable)
  fakebin=$(make_fakebin "$home")
  out=$(run_snapshot "$home" "$fakebin") || fail "registry snapshot failed for missing-input fixture"
  printf '%s' "$out" | jq -e '
    .status == "degraded" and
    .counts.registered_projects == {value:null,status:"unavailable"} and
    .counts.registered_secondmates == {value:null,status:"unavailable"} and
    .counts.active_tasks == {value:null,status:"unavailable"} and
    .counts.queued_tasks == {value:null,status:"unavailable"} and
    .counts.completed_tasks == {value:null,status:"unavailable"}
  ' >/dev/null || fail "missing private inputs were inferred as zero"

  malformed='LEAK_MALFORMED_PRIVATE_CONTENT_6e91a3'
  printf -- '- malformed [unknown-mode] - %s\n' "$malformed" > "$home/data/projects.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
$malformed

## Queued

## Done
EOF
  printf -- '- bad-mate - %s\n' "$malformed" > "$home/data/secondmates.md"
  printf 'FMX_PAIRING_TOKEN=%s\n' "$malformed" > "$home/.env"
  chmod 000 "$home/.env"
  out=$(run_snapshot "$home" "$fakebin") || fail "registry snapshot failed for malformed-input fixture"
  chmod 600 "$home/.env"

  assert_not_contains "$out" "$malformed" "malformed private content leaked into unavailable output"
  printf '%s' "$out" | jq -e '
    .status == "degraded" and
    .posture.x_mode_enabled == {value:null,status:"unavailable"} and
    .counts.registered_projects == {value:null,status:"unavailable"} and
    .counts.registered_secondmates == {value:null,status:"unavailable"} and
    .counts.active_tasks == {value:null,status:"unavailable"} and
    (.unavailable_fields | index("posture.x_mode_enabled") != null) and
    (.unavailable_fields | index("counts.registered_projects") != null)
  ' >/dev/null || fail "malformed or unreadable state lacked structured unavailable markers"
  pass "missing, unreadable, and malformed inputs degrade explicitly without leaking content"
}

test_existing_bearings_contract_remains_unchanged() {
  local home fakebin out
  home=$(make_home bearings-compat)
  fakebin=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  out=$(run_bearings "$home" "$fakebin") || fail "existing bearings command failed"
  printf '%s' "$out" | jq -e '
    .schema == "fm-bearings.v1" and
    (keys | sort) == ["decisions_open","gates","generated","home","in_flight","landed","omitted","prs","recorded_prs","reports","schema","secondmates"]
  ' >/dev/null || fail "existing fm-bearings.v1 JSON shape changed"
  pass "existing fm-bearings.v1 output shape remains unchanged"
}

test_shell_and_static_checks_pass() {
  bash -n "$SNAPSHOT" || fail "registry snapshot failed bash syntax validation"
  bash -n "$ROOT/bin/fm-harness.sh" || fail "harness declaration failed bash syntax validation"
  git -C "$ROOT" diff --check || fail "git diff --check failed"
  pass "registry snapshot passes shell syntax and static diff checks"
}

test_schema_exact_keys_and_types
test_local_mode_makes_no_network_calls
test_leak_sentinels_never_reach_serialized_output
test_aggregate_counts_match_complete_fixture
test_posture_values_stay_inside_allowlists
test_missing_unreadable_and_malformed_inputs_degrade_without_leaking
test_existing_bearings_contract_remains_unchanged
test_shell_and_static_checks_pass

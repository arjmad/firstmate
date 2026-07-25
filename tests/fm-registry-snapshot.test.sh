#!/usr/bin/env bash
# Behavior tests for the bounded fm-registry-snapshot.v1 operational contract.
# Covers exact schema, determinism, local-only/read-only behavior, structured
# project/secondmate/task rows, local delivery evidence, current-vs-event semantics,
# consistency diagnostics, aggregate cross-checks, degradation/truncation, secret
# and wholesale-content exclusions, bearings compatibility, and static validation.
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
set -u
case "${1:-}" in
  axi)
    case "${2:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "$*" in *fm-dead*) exit 1 ;; *) printf '%%1\n' ;; esac
    ;;
  capture-pane) printf 'PANE_TRANSCRIPT_SENTINEL_70c6a1\nall quiet\n> \n' ;;
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
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/task-worktrees"
  printf '%s\n' "$home"
}

make_git_repo() {  # <path> <branch>
  fm_git_init_commit "$1"
  if git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then
    git -C "$1" checkout -q "$2"
  else
    git -C "$1" checkout -qb "$2"
  fi
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
  make_git_repo "$mate/projects/mate-active" fm/mate-active
  fm_write_meta "$mate/state/mate-active.meta" \
    'window=firstmate:fm-mate-active' \
    "worktree=$mate/projects/mate-active" \
    'project=alpha' \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    'model=claude-sonnet-5' \
    'effort=high'
  printf 'working: secondmate fixture activity\n' > "$mate/state/mate-active.status"
  printf '%s\n' "$mate"
}

write_complete_fixture() {  # <home>
  local home=$1 mate active_head
  mate=$(make_secondmate_home mate-one "$(basename "$home")-mate")
  cat > "$home/data/projects.md" <<'EOF'
- alpha [no-mistakes] - first fixture project (added 2026-07-24)
- beta [local-only +yolo] - second fixture project (added 2026-07-24)
EOF
  make_git_repo "$home/projects/alpha" main
  git -C "$home/projects/alpha" remote add origin 'https://user:ghp_REMOTE_SECRET_1234567890@github.com/acme/alpha.git'
  make_git_repo "$home/projects/beta" main
  git -C "$home/projects/beta" remote add origin 'git@github.com:acme/beta.git'

  printf -- '- mate-one - Fixture domain (home: %s; scope: registry verification and delivery work; projects: alpha, beta; added 2026-07-24)\n' \
    "$mate" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-one - Active validation task (repo: alpha) (kind: ship) (since 2026-07-24)
- [ ] done-no-pr - Worker-reported done without delivery (repo: alpha) (kind: ship) (since 2026-07-24)
- [ ] scout-without-report - Completed scout without report (repo: alpha) (kind: scout) (since 2026-07-24)
- [ ] decision-one - Waiting on a bounded decision (repo: alpha) (kind: ship) (since 2026-07-24)

## Queued
- [ ] queued-one - Queued fixture task (repo: beta) (kind: ship)

## Done
- [x] done-one - Completed fixture task https://github.com/acme/alpha/pull/7 (repo: alpha) (kind: ship) (done 2026-07-24)
- [x] scout-with-report - Completed scout with report data/scout-with-report/report.md (repo: alpha) (kind: scout) (reported 2026-07-24)
- [x] scout-report-retained - Retained scout report without task metadata data/scout-report-retained/report.md (repo: alpha) (kind: scout) (reported 2026-07-24)
- [x] promoted-stale-scout - Promoted ship left with a stale scout annotation (repo: alpha) (kind: scout) (done 2026-07-24)
EOF

  make_git_repo "$home/task-worktrees/active-one" fm/active-one
  active_head=$(git -C "$home/task-worktrees/active-one" rev-parse HEAD)
  fm_write_meta "$home/state/active-one.meta" \
    'window=firstmate:fm-active-one' \
    "worktree=$home/task-worktrees/active-one" \
    "project=$home/projects/alpha" \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    'model=gpt-5.6-sol' \
    'effort=xhigh' \
    'pr=https://github.com/acme/alpha/pull/9' \
    "pr_head=$active_head"
  cat > "$home/state/active-one.status" <<'EOF'
working: RAW_FULL_STATUS_LOG_SENTINEL_9a4d13
blocked: stale event history, not current truth
EOF

  make_git_repo "$home/task-worktrees/done-no-pr" fm/done-no-pr
  fm_write_meta "$home/state/done-no-pr.meta" \
    'window=firstmate:fm-done-no-pr' \
    "worktree=$home/task-worktrees/done-no-pr" \
    "project=$home/projects/alpha" \
    'harness=claude' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    'model=claude-sonnet-5' \
    'effort=high'
  printf 'done: implementation committed locally\n' > "$home/state/done-no-pr.status"
  mkdir -p "$home/data/done-no-pr"
  printf 'RAW_REPORT_SENTINEL_5108d4\n' > "$home/data/done-no-pr/report.md"
  printf 'RAW_BRIEF_SENTINEL_1bf889\n' > "$home/data/done-no-pr/brief.md"

  make_git_repo "$home/task-worktrees/scout-with-report" fm/scout-with-report
  fm_write_meta "$home/state/scout-with-report.meta" \
    'window=firstmate:fm-scout-with-report' \
    "worktree=$home/task-worktrees/scout-with-report" \
    "project=$home/projects/alpha" \
    'harness=claude' \
    'kind=scout' \
    'mode=no-mistakes' \
    'yolo=off' \
    'model=claude-sonnet-5' \
    'effort=high'
  printf 'done: scout report complete\n' > "$home/state/scout-with-report.status"
  mkdir -p "$home/data/scout-with-report"
  printf '# Scout report\n\nFindings are complete.\n' > "$home/data/scout-with-report/report.md"

  # Retained genuine scout whose task metadata was already cleaned up: only the
  # backlog report link and the canonical report artifact remain.
  mkdir -p "$home/data/scout-report-retained"
  printf '# Scout report\n\nRetained after teardown.\n' > "$home/data/scout-report-retained/report.md"

  # Promoted ship whose backlog row still carries the stale scout annotation and an
  # old scout-phase report file, but no recorded report completion and no PR.
  mkdir -p "$home/data/promoted-stale-scout"
  printf '# Scout report\n\nSuperseded by ship delivery.\n' > "$home/data/promoted-stale-scout/report.md"

  # Worker-reported done carrying only a kind=scout annotation and no report artifact:
  # the annotation alone must not buy the scout delivery exemption.
  make_git_repo "$home/task-worktrees/scout-without-report" fm/scout-without-report
  fm_write_meta "$home/state/scout-without-report.meta" \
    'window=firstmate:fm-scout-without-report' \
    "worktree=$home/task-worktrees/scout-without-report" \
    "project=$home/projects/alpha" \
    'harness=claude' \
    'kind=scout' \
    'mode=no-mistakes' \
    'yolo=off' \
    'model=claude-sonnet-5' \
    'effort=high'
  printf 'done: scout report complete\n' > "$home/state/scout-without-report.status"

  make_git_repo "$home/task-worktrees/decision-one" fm/decision-one
  fm_write_meta "$home/state/decision-one.meta" \
    'window=firstmate:fm-dead' \
    "worktree=$home/task-worktrees/decision-one" \
    "project=$home/projects/alpha" \
    'harness=pi' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    'model=claude-opus-4-8' \
    'effort=medium'
  printf 'needs-decision [key=choice]: choose safe option ghp_DECISION_SECRET_1234567890\n' > "$home/state/decision-one.status"

  fm_write_meta "$home/state/mate-one.meta" \
    'window=firstmate:fm-dead-mate-one' \
    "worktree=$mate" \
    "project=$mate" \
    'harness=claude' \
    'kind=secondmate' \
    'mode=secondmate' \
    'yolo=off' \
    'model=claude-opus-4-8' \
    'effort=high' \
    "home=$mate" \
    'projects=alpha,beta'

  cat > "$home/config/crew-harness" <<'EOF'
codex
EOF
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"when":"registry work","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}],"select":"quota-balanced"}],"default":{"harness":"pi","effort":"medium"}}
EOF
  cat > "$home/config/secondmate-harness" <<'EOF'
claude claude-opus-4-8 high
EOF
  cat > "$home/.env" <<'EOF'
FMX_PAIRING_TOKEN=ghp_XMODE_SECRET_1234567890
EOF
  cat > "$home/active-run.out" <<EOF
run:
  id: "01RUN"
  branch: fm/active-one
  status: running
  head: "$active_head"
  pr: "https://github.com/acme/alpha/pull/9"
  findings: none
EOF
}

run_snapshot() {  # <home> <fakebin> [backend]
  local home=$1 fakebin=$2 backend=${3:-tmux}
  : > "$home/net.log"
  PATH="$fakebin:$PATH" \
    NET_LOG="$home/net.log" \
    FM_HOME="$home" \
    FM_BACKEND="$backend" \
    FM_FAKE_AXI_STATUS="$(test -f "$home/active-run.out" && printf '%s' "$(<"$home/active-run.out")")" \
    FM_FAKE_RUNS_LIST='' \
    SECRET_ENV_SENTINEL='RAW_ENV_SENTINEL_652e6c' \
    TMUX='' HERDR_ENV=0 CMUX_WORKSPACE_ID='' __CFBundleIdentifier='' \
    FM_REGISTRY_SNAPSHOT_NOW=2026-07-24T12:34:56Z \
    FM_REGISTRY_PROJECTS="${FM_REGISTRY_PROJECTS:-50}" \
    FM_REGISTRY_SECONDMATES="${FM_REGISTRY_SECONDMATES:-20}" \
    FM_REGISTRY_TASKS_PER_SECTION="${FM_REGISTRY_TASKS_PER_SECTION:-50}" \
    FM_REGISTRY_DIAGNOSTICS="${FM_REGISTRY_DIAGNOSTICS:-100}" \
    FM_REGISTRY_ROUTING_RULES="${FM_REGISTRY_ROUTING_RULES:-50}" \
    FM_SNAPSHOT_REGISTRY_BYTES="${FM_SNAPSHOT_REGISTRY_BYTES:-65536}" \
    "${SNAPSHOT_UNDER_TEST:-$SNAPSHOT}" --json
}

run_bearings() {  # <home> <fakebin>
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" NET_LOG="$home/net.log" FM_HOME="$home" \
    TMUX='' HERDR_ENV=0 CMUX_WORKSPACE_ID='' __CFBundleIdentifier='' \
    FM_BEARINGS_NOW=2026-07-24T12:34:56Z "$BEARINGS" --json
}

fingerprint_state() {  # <home>
  find "$1/data" "$1/state" "$1/config" -type f -print0 \
    | sort -z \
    | xargs -0 shasum 2>/dev/null
}

test_exact_versioned_schema_and_types() {
  local home fakebin out help
  home=$(make_home schema)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "operational snapshot failed for schema fixture"
  printf '%s' "$out" | jq -e '
    (keys|sort) == ["configuration","counts","diagnostics","generated","limits","omissions","projects","provenance","schema","secondmates","status","tasks","unavailable_fields"] and
    .schema == "fm-registry-snapshot.v1" and
    (.status|IN("available","degraded","unavailable")) and
    (.limits|keys|sort) == ["diagnostics","projects","routing_rules","secondmates","tasks_per_section"] and
    (.provenance|keys|sort) == ["canonical_snapshot","home","source"] and
    (.configuration|keys|sort) == ["autonomy","delivery","routing","runtime_backend","status","verified_adapters","x_mode_enabled"] and
    (.configuration.routing|keys|sort) == ["crew","crew_dispatch","primary","secondmate"] and
    (.configuration.routing.crew_dispatch
      | .configured==true and .status=="available" and .rule_count==1
        and .rules[0].selector=="quota-balanced"
        and .rules[0].profiles[0]=={"harness":"claude","model":"claude-sonnet-5","model_truncated":false,"effort":"high"}
        and .default_profile=={"harness":"pi","model":null,"model_truncated":false,"effort":"medium"}) and
    (.projects.records|type)=="array" and (.secondmates.records|type)=="array" and
    (.tasks|keys|sort)==["complete","in_flight","omissions","queued","retained_done","status"] and
    (.diagnostics.records|type)=="array" and (.counts|type)=="object"
  ' >/dev/null || fail "operational schema keys or types drifted"
  help=$("$SNAPSHOT" --help) || fail "operational snapshot help failed"
  assert_contains "$help" 'fm-registry-snapshot.v1' "help omitted schema"
  assert_contains "$help" 'local-only' "help omitted local-only contract"
  pass "operational snapshot has exact versioned schema and types"
}

test_deterministic_for_fixed_state_and_time() {
  local home fakebin first second
  home=$(make_home deterministic)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  first=$(run_snapshot "$home" "$fakebin") || fail "first deterministic snapshot failed"
  second=$(run_snapshot "$home" "$fakebin") || fail "second deterministic snapshot failed"
  [ "$first" = "$second" ] || fail "fixed local state produced different snapshots"
  pass "operational snapshot is deterministic for fixed state and time"
}

test_zero_network_and_github_calls() {
  local home fakebin
  home=$(make_home no-network)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  run_snapshot "$home" "$fakebin" >/dev/null || fail "local operational snapshot failed"
  [ ! -s "$home/net.log" ] || fail "operational snapshot invoked a network or GitHub tool"
  pass "operational snapshot performs zero network and GitHub calls"
}

test_read_only_no_firstmate_state_mutation() {
  local home fakebin before after
  home=$(make_home read-only)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  before=$(fingerprint_state "$home")
  run_snapshot "$home" "$fakebin" >/dev/null || fail "read-only operational snapshot failed"
  after=$(fingerprint_state "$home")
  [ "$before" = "$after" ] || fail "operational snapshot mutated FirstMate data/state/config"
  pass "operational snapshot does not mutate FirstMate state"
}

test_structured_project_secondmate_and_task_rows() {
  local home fakebin out
  home=$(make_home structured-rows)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "structured operational snapshot failed"
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.projects.records[] | select(.key=="alpha")
      | .delivery_mode=="no-mistakes" and .yolo==false and .local.exists==true
        and .local.git_repository==true and .remote.identity=="github.com/acme/alpha") and
    (.projects.records[] | select(.key=="beta") | .delivery_mode=="local-only" and .yolo==true) and
    (.secondmates.records[] | select(.id=="mate-one")
      | .registry.scope=="registry verification and delivery work"
        and .registry.projects==["alpha","beta"] and .runtime.harness=="claude"
        and .runtime.model=="claude-opus-4-8" and .workload.active_tasks==1
        and .endpoint.exists==false and (.diagnostics|index("endpoint_unhealthy"))!=null) and
    (.tasks.in_flight.records[] | select(.id=="active-one")
      | .title=="Active validation task" and .project=="alpha" and .runtime.harness=="codex"
        and .runtime.model=="gpt-5.6-sol" and .runtime.effort=="xhigh"
        and .implementation.branch=="fm/active-one"
        and .implementation.worktree==($home+"/task-worktrees/active-one")) and
    (.tasks.queued.records[] | select(.id=="queued-one") | .current.state=="queued") and
    (.tasks.retained_done.records[] | select(.id=="done-one")
      | .current.state=="done" and .delivery.yolo==false)
  ' >/dev/null || fail "project, secondmate, or task rows were incomplete"
  pass "operational snapshot emits structured project, secondmate, and task rows"
}

test_local_delivery_validation_and_pr_evidence() {
  local home fakebin out active_head
  home=$(make_home delivery-evidence)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  active_head=$(git -C "$home/task-worktrees/active-one" rev-parse HEAD)
  out=$(run_snapshot "$home" "$fakebin") || fail "delivery evidence snapshot failed"
  printf '%s' "$out" | jq -e --arg head "$active_head" '
    (.tasks.in_flight.records[] | select(.id=="active-one")
      | .delivery_evidence.validation.required==true
        and .delivery_evidence.validation.source=="run-step"
        and .delivery_evidence.validation.state=="working"
        and .delivery_evidence.pr.url=="https://github.com/acme/alpha/pull/9"
        and .delivery_evidence.pr.head==$head
        and .delivery_evidence.pr.source=="meta") and
    (.tasks.in_flight.records[] | select(.id=="done-no-pr")
      | .delivery_evidence.validation.state=="missing"
        and .delivery_evidence.pr.url==null
        and .implementation.push_state=="no_upstream") and
    (.tasks.retained_done.records[] | select(.id=="done-one")
      | .delivery_evidence.pr.url=="https://github.com/acme/alpha/pull/7"
        and .delivery_evidence.pr.source=="backlog")
  ' >/dev/null || fail "local validation, branch, or PR evidence semantics were wrong"
  pass "operational snapshot exposes local delivery, validation, and PR evidence"
}

test_reconciled_current_state_vs_event_history() {
  local home fakebin out
  home=$(make_home current-vs-event)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "current/event snapshot failed"
  printf '%s' "$out" | jq -e '
    .tasks.in_flight.records[] | select(.id=="active-one")
    | .current.state=="working" and .current.source=="run-step"
      and .event_history.role=="event_history" and .event_history.category=="blocked"
      and .event_history.summary=="stale event history, not current truth"
  ' >/dev/null || fail "event history replaced reconciled current state"
  pass "operational snapshot labels event history separately from current state"
}

test_machine_readable_contradiction_diagnostics() {
  local home fakebin out
  home=$(make_home diagnostics)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "diagnostic snapshot failed"
  printf '%s' "$out" | jq -e '
    (.tasks.in_flight.records[] | select(.id=="done-no-pr")
      | (.diagnostics|sort)==["branch_not_pushed","reported_done_without_required_pr","validation_missing"]) and
    (.tasks.retained_done.records[] | select(.id=="scout-with-report")
      | .kind=="scout" and .delivery_evidence.validation.required==false
        and .delivery_evidence.validation.source=="scout_report"
        and .delivery_evidence.pr.url==null
        and .implementation.push_state=="no_upstream" and (.diagnostics|length)==0) and
    (.tasks.retained_done.records[] | select(.id=="scout-report-retained")
      | .kind=="scout" and .delivery_evidence.validation.required==false
        and .delivery_evidence.validation.source=="scout_report" and (.diagnostics|length)==0) and
    (.tasks.retained_done.records[] | select(.id=="promoted-stale-scout")
      | .kind=="scout" and .delivery_evidence.validation.required==true
        and .diagnostics==["reported_done_without_required_pr"]) and
    (.tasks.retained_done.records[] | select(.id=="done-one") | (.diagnostics|length)==0) and
    (.tasks.in_flight.records[] | select(.id=="scout-without-report")
      | .kind=="scout" and .delivery_evidence.validation.required==true
        and .delivery_evidence.validation.source=="none"
        and (.diagnostics|sort)==["branch_not_pushed","reported_done_without_required_pr",
                                  "reported_done_without_scout_report","validation_missing"]) and
    (.tasks.in_flight.records[] | select(.id=="decision-one")
      | (.diagnostics|index("endpoint_unhealthy"))!=null) and
    .diagnostics.by_code.reported_done_without_required_pr==3 and
    .diagnostics.by_code.reported_done_without_scout_report==1 and
    .diagnostics.by_code.validation_missing==2 and
    .diagnostics.by_code.branch_not_pushed==2 and
    .diagnostics.by_code.endpoint_unhealthy==2 and
    (.diagnostics.records | any(.record_id=="scout-without-report"
      and .code=="reported_done_without_scout_report" and .severity=="warning"))
  ' >/dev/null || fail "required contradiction diagnostics were absent or unstructured"
  pass "operational snapshot reports machine-readable delivery contradictions"
}

test_absent_scout_report_index_degrades_explicitly() {
  local home fakebin stub_bin entry out
  home=$(make_home scoutindex)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"

  # The scout delivery exemption is decided on the canonical durable report index.
  # A canonical snapshot that omits that index looks exactly like one where no
  # scout ever filed a report, so treating it as empty would silently restore the
  # false-positive delivery findings for every delivered scout. Stub the canonical
  # snapshot to drop the index and require explicit unavailability instead.
  stub_bin=$home/stub-bin
  mkdir -p "$stub_bin"
  for entry in "$ROOT"/bin/*; do
    ln -s "$entry" "$stub_bin/$(basename "$entry")"
  done
  rm -f "$stub_bin/fm-fleet-snapshot.sh"
  cat > "$stub_bin/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
set -u
"$ROOT/bin/fm-fleet-snapshot.sh" "\$@" | jq 'del(.scout_reports)'
SH
  chmod +x "$stub_bin/fm-fleet-snapshot.sh"

  out=$(SNAPSHOT_UNDER_TEST="$stub_bin/fm-registry-snapshot.sh" run_snapshot "$home" "$fakebin") \
    || fail "snapshot without a canonical scout-report index exited non-zero"
  printf '%s' "$out" | jq -e '
    .status=="unavailable" and
    .provenance.canonical_snapshot.status=="unavailable" and
    (.unavailable_fields|index("provenance.canonical_snapshot"))!=null
  ' >/dev/null || fail "absent canonical scout-report index was not explicit"

  out=$(run_snapshot "$home" "$fakebin") || fail "baseline snapshot failed"
  printf '%s' "$out" | jq -e '
    .provenance.canonical_snapshot.status=="available" and
    (.tasks.retained_done.records[] | select(.id=="scout-with-report") | (.diagnostics|length)==0)
  ' >/dev/null || fail "canonical scout-report index was not consumed as available"
  pass "absent canonical scout-report index degrades explicitly instead of silently"
}

test_aggregates_match_detailed_bounded_rows() {
  local home fakebin out orphan
  home=$(make_home aggregates)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "aggregate snapshot failed"
  printf '%s' "$out" | jq -e '
    .counts.registered_projects.value==.projects.total and
    .counts.registered_secondmates.value==.secondmates.total_registered and
    .counts.active_tasks.value==(.tasks.in_flight.total + ([.secondmates.records[].workload.active_tasks]|add)) and
    .counts.queued_tasks.value==(.tasks.queued.total + ([.secondmates.records[].workload.queued_tasks]|add)) and
    .counts.retained_done_tasks.value==(.tasks.retained_done.total + ([.secondmates.records[].workload.retained_done_tasks]|add)) and
    .counts.diagnostics.value==.diagnostics.total and
    .counts.diagnostics_by_code==.diagnostics.by_code
  ' >/dev/null || fail "aggregate counts disagreed with detailed rows"

  home=$(make_home aggregates-orphan)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  orphan=$(make_secondmate_home mate-orphan "$(basename "$home")-mate2")
  fm_write_meta "$home/state/mate-orphan.meta" \
    'window=firstmate:fm-dead-mate-orphan' \
    "worktree=$orphan" \
    "project=$orphan" \
    'harness=claude' \
    'kind=secondmate' \
    'mode=secondmate' \
    'yolo=off' \
    'model=claude-opus-4-8' \
    'effort=high' \
    "home=$orphan" \
    'projects=alpha'
  out=$(run_snapshot "$home" "$fakebin") || fail "orphan secondmate snapshot failed"
  printf '%s' "$out" | jq -e '
    .secondmates.total==2 and .secondmates.total_registered==1 and
    .counts.registered_secondmates.value==1 and
    .counts.registered_secondmates.status=="available" and
    ([.secondmates.records[]|select(.registry.status=="available")]|length)==.counts.registered_secondmates.value
  ' >/dev/null || fail "unregistered secondmate metadata inflated the registered count"
  pass "operational aggregate counts cross-check against detailed rows"
}

test_missing_unreadable_malformed_incomplete_and_truncated_inputs() {
  local home fakebin out malformed truncated long_model long_project long_scope long_title content
  home=$(make_home unavailable)
  fakebin=$(make_fakebin "$home")
  out=$(run_snapshot "$home" "$fakebin") || fail "missing-input snapshot failed"
  printf '%s' "$out" | jq -e '
    .status=="degraded" and .projects.status=="unavailable" and
    .tasks.status=="unavailable" and .counts.registered_projects.status=="unavailable" and
    .diagnostics.status=="unavailable" and .counts.diagnostics.status=="unavailable"
  ' >/dev/null || fail "missing inputs were not explicit"

  malformed='MALFORMED_PRIVATE_SENTINEL_a9e801'
  printf -- '- bad [unknown-mode] - %s\nnot-a-project-row\n' "$malformed" > "$home/data/projects.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
$malformed

## Queued

## Done
EOF
  printf -- '- bad-mate - %s\n' "$malformed" > "$home/data/secondmates.md"
  printf '{"rules":[{"when":"%s","use":{"harness":"unknown"}}]}\n' "$malformed" > "$home/config/crew-dispatch.json"
  printf 'FMX_PAIRING_TOKEN=ghp_UNREADABLE_SECRET_1234567890\n' > "$home/.env"
  chmod 000 "$home/.env"
  out=$(run_snapshot "$home" "$fakebin") || fail "malformed-input snapshot failed"
  chmod 600 "$home/.env"
  assert_not_contains "$out" "$malformed" "malformed private content leaked"
  printf '%s' "$out" | jq -e '
    .configuration.x_mode_enabled.status=="unavailable" and
    .configuration.routing.crew_dispatch.status=="unavailable" and
    (.projects.records|any(.status=="unavailable")) and
    (.tasks.in_flight.records|any((.diagnostics|index("malformed_backlog_record"))!=null)) and
    (.secondmates.records|any(.id=="bad-mate" and .status=="unavailable"
      and (.diagnostics|index("malformed_secondmate_registry_entry"))!=null))
  ' >/dev/null || fail "malformed or unreadable inputs lacked explicit degradation"

  printf '%s\n%s\n' '{"rules":[]}' '{"rules":[]}' > "$home/config/crew-dispatch.json"
  out=$(run_snapshot "$home" "$fakebin") || fail "multi-document crew-dispatch snapshot exited non-zero"
  printf '%s' "$out" | jq -e '
    .schema=="fm-registry-snapshot.v1" and
    .configuration.routing.crew_dispatch.configured==true and
    .configuration.routing.crew_dispatch.status=="unavailable"
  ' >/dev/null || fail "multi-document crew-dispatch lacked structured degradation"

  home=$(make_home truncated)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  printf -v long_model '%*s' 220 ''
  long_model=${long_model// /m}
  printf -v long_project '%*s' 180 ''
  long_project=${long_project// /p}
  printf -v long_scope '%*s' 260 ''
  long_scope=${long_scope// /s}
  printf -v long_title '%*s' 220 ''
  long_title=${long_title// /t}
  printf -- '- %s [no-mistakes] - field truncation fixture\n- beta [local-only +yolo] - second fixture project\n' \
    "$long_project" > "$home/data/projects.md"
  content=$(<"$home/data/secondmates.md")
  printf '%s\n' "${content/registry verification and delivery work/$long_scope}" > "$home/data/secondmates.md"
  content=$(<"$home/data/backlog.md")
  printf '%s\n' "${content/Queued fixture task/$long_title}" > "$home/data/backlog.md"
  printf '{"rules":[{"when":"one","use":{"harness":"claude","model":"%s"}},{"when":"two","use":{"harness":"codex"}}]}\n' \
    "$long_model" > "$home/config/crew-dispatch.json"
  out=$(FM_REGISTRY_PROJECTS=1 FM_REGISTRY_TASKS_PER_SECTION=1 FM_REGISTRY_ROUTING_RULES=1 \
    run_snapshot "$home" "$fakebin") || fail "truncated snapshot failed"
  truncated=$out
  printf '%s' "$truncated" | jq -e '
    .projects.truncated>0 and .tasks.in_flight.truncated>0 and
    (.projects.records[0].truncated_fields|index("key"))!=null and (.projects.records[0].key|length)==160 and
    (.secondmates.records[0].truncated_fields|index("registry.scope"))!=null and
    (.secondmates.records[0].registry.scope|length)==240 and
    (.tasks.queued.records[0].truncated_fields|index("title"))!=null and
    (.tasks.queued.records[0].title|length)==200 and
    .configuration.routing.crew_dispatch.truncated==1 and
    .configuration.routing.crew_dispatch.rules[0].profiles[0].model_truncated==true and
    (.configuration.routing.crew_dispatch.rules[0].profiles[0].model|length)==200 and
    (.omissions|any(.section=="projects" and .reason=="field_limit")) and
    (.omissions|any(.section=="secondmates" and .reason=="field_limit")) and
    (.omissions|any(.section=="tasks.queued" and .reason=="field_limit")) and
    (.omissions|any(.section=="configuration.routing.crew_dispatch" and .reason=="record_limit"))
  ' >/dev/null || fail "field or record truncation was not explicit"
  out=$(FM_SNAPSHOT_REGISTRY_BYTES=40 run_snapshot "$home" "$fakebin") || fail "input-limited snapshot failed"
  printf '%s' "$out" | jq -e '
    .secondmates.complete==false and
    (.omissions|any(.section=="secondmates" and .reason=="input_limit"))
  ' >/dev/null || fail "bounded input truncation was not explicit"
  pass "operational snapshot exposes missing, malformed, incomplete, and truncated inputs"
}

test_secret_token_and_environment_sentinels_never_serialize() {
  local home fakebin out sentinel
  home=$(make_home secrets)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  printf '%s\n' \
    'model=ghp_META_SECRET_1234567890' \
    'pr_head=ghp_HEAD_SECRET_1234567890' \
    'pr=https://user:CREDENTIAL_SENTINEL_1234567890@github.com/acme/alpha/pull/99' \
    >> "$home/state/decision-one.meta"
  printf '%s\n' 'claude ghp_CONFIG_SECRET_1234567890 high' > "$home/config/secondmate-harness"
  printf '%s\n' '{"default":{"harness":"claude","model":"ghp_DISPATCH_SECRET_1234567890","effort":"high"}}' > "$home/config/crew-dispatch.json"
  printf '%s\n' '- ghp_PROJECT_SECRET_1234567890 [local-only] - secret-shaped project key' >> "$home/data/projects.md"
  make_git_repo "$home/projects/gamma" main
  git -C "$home/projects/gamma" remote add origin 'https://alice:p@ssw0rd-CREDAT_SENTINEL_9f2b1c@github.com/acme/gamma.git'
  make_git_repo "$home/projects/delta" main
  git -C "$home/projects/delta" remote add origin 'https://github.com/acme/del@ta.git'
  make_git_repo "$home/projects/epsilon" main
  git -C "$home/projects/epsilon" remote add origin 'ci@bot@github.com:acme/epsilon.git'
  printf '%s\n' \
    '- gamma [no-mistakes] - remote password containing an at sign' \
    '- delta [no-mistakes] - credential-free remote path containing an at sign' \
    '- epsilon [no-mistakes] - scp remote userinfo containing an at sign' \
    >> "$home/data/projects.md"
  out=$(run_snapshot "$home" "$fakebin") || fail "secret sentinel snapshot failed"
  for sentinel in \
    ghp_REMOTE_SECRET_1234567890 \
    ghp_XMODE_SECRET_1234567890 \
    ghp_DECISION_SECRET_1234567890 \
    ghp_META_SECRET_1234567890 \
    ghp_HEAD_SECRET_1234567890 \
    ghp_CONFIG_SECRET_1234567890 \
    ghp_DISPATCH_SECRET_1234567890 \
    ghp_PROJECT_SECRET_1234567890 \
    CREDENTIAL_SENTINEL_1234567890 \
    CREDAT_SENTINEL_9f2b1c \
    RAW_ENV_SENTINEL_652e6c \
    'user:ghp_'; do
    assert_not_contains "$out" "$sentinel" "secret or environment sentinel leaked: $sentinel"
  done
  printf '%s' "$out" | jq -e '
    (.projects.records[] | select(.key=="gamma")
      | .remote.identity=="github.com/acme/gamma" and .remote.locator=="https://github.com/acme/gamma") and
    (.projects.records[] | select(.key=="delta") | .remote.identity=="github.com/acme/del@ta") and
    (.projects.records[] | select(.key=="epsilon")
      | .remote.kind=="ssh" and .remote.identity=="github.com/acme/epsilon") and
    .configuration.routing.crew_dispatch.status=="unavailable" and
    .configuration.routing.secondmate.model==null and
    .configuration.routing.secondmate.status=="unavailable" and
    (.tasks.in_flight.records[] | select(.id=="decision-one")
      | .runtime.model==null and .delivery_evidence.pr.head==null
        and .delivery_evidence.pr.url=="https://github.com/acme/alpha/pull/99")
  ' >/dev/null || fail "secret-bearing structured fields were not withheld"
  assert_contains "$out" '[redacted]' "token-shaped decision summary was not redacted"
  pass "operational snapshot never serializes secret, token, or environment values"
}

test_raw_transcript_pane_log_brief_and_report_never_serialize() {
  local home fakebin out sentinel
  home=$(make_home raw-content)
  fakebin=$(make_fakebin "$home")
  write_complete_fixture "$home"
  out=$(run_snapshot "$home" "$fakebin") || fail "raw-content snapshot failed"
  for sentinel in \
    PANE_TRANSCRIPT_SENTINEL_70c6a1 \
    RAW_FULL_STATUS_LOG_SENTINEL_9a4d13 \
    RAW_REPORT_SENTINEL_5108d4 \
    RAW_BRIEF_SENTINEL_1bf889; do
    assert_not_contains "$out" "$sentinel" "wholesale raw content leaked: $sentinel"
  done
  assert_contains "$out" 'done-no-pr' "allowed task ID was incorrectly removed"
  assert_contains "$out" 'Worker-reported done without delivery' "allowed concise title was incorrectly removed"
  assert_contains "$out" 'fm/done-no-pr' "allowed branch was incorrectly removed"
  pass "operational snapshot excludes raw transcripts, panes, logs, briefs, and reports"
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
    .schema=="fm-bearings.v1" and
    (keys|sort)==["decisions_open","gates","generated","home","in_flight","landed","omitted","prs","recorded_prs","reports","schema","secondmates"]
  ' >/dev/null || fail "fm-bearings.v1 output shape changed"
  pass "existing fm-bearings.v1 output remains unchanged"
}

test_shell_static_and_diff_checks_pass() {
  bash -n "$SNAPSHOT" || fail "registry snapshot failed bash syntax"
  bash -n "$ROOT/bin/fm-fleet-snapshot.sh" || fail "canonical snapshot failed bash syntax"
  git -C "$ROOT" diff --check || fail "git diff --check failed"
  pass "operational snapshot passes shell syntax and static diff checks"
}

test_exact_versioned_schema_and_types
test_deterministic_for_fixed_state_and_time
test_zero_network_and_github_calls
test_read_only_no_firstmate_state_mutation
test_structured_project_secondmate_and_task_rows
test_local_delivery_validation_and_pr_evidence
test_reconciled_current_state_vs_event_history
test_machine_readable_contradiction_diagnostics
test_absent_scout_report_index_degrades_explicitly
test_aggregates_match_detailed_bounded_rows
test_missing_unreadable_malformed_incomplete_and_truncated_inputs
test_secret_token_and_environment_sentinels_never_serialize
test_raw_transcript_pane_log_brief_and_report_never_serialize
test_existing_bearings_contract_remains_unchanged
test_shell_static_and_diff_checks_pass

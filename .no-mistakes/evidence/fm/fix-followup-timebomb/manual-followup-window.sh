#!/usr/bin/env bash
# Manual end-to-end evidence: seed a real public-followup obligation the way the
# fixture does, then ask the real CLI (bin/fm-public-followup.sh pending) what it
# says about the thread window -- once with the fixture's clock-relative dates
# (target commit) and once with the old hardcoded 2026-08-28 date (base commit).
set -u
ROOT=${ROOT:?set ROOT to the worktree}
PF="$ROOT/bin/fm-public-followup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-followup-evidence.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

iso_utc_from_epoch() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
FOLLOWUP_EXPIRES_EPOCH=$(($(date -u +%s) + 30*24*60*60))
FOLLOWUP_EXPIRES_AT=$(iso_utc_from_epoch "$FOLLOWUP_EXPIRES_EPOCH")
FOLLOWUP_OBLIGATION_EXPIRES_AT=$(iso_utc_from_epoch $((FOLLOWUP_EXPIRES_EPOCH + 30*24*60*60)))

echo "today (UTC):                 $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "retained thread window ends: $FOLLOWUP_EXPIRES_AT   (now + 30d)"
echo "obligation expires:          $FOLLOWUP_OBLIGATION_EXPIRES_AT   (now + 60d, deliberately distinct)"
echo

scenario() {  # <label> <followup_expires_at> <obligation_expires_at>
  local label=$1 fexp=$2 oexp=$3
  local home="$TMP_ROOT/$label"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf 'FMX_PAIRING_TOKEN=test-token\n' > "$home/.env"
  for c in curl tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$c"; chmod +x "$home/fakebin/$c"; done
  jq -n --arg e "$fexp" '{request_id:"req-evidence", platform:"discord",
      context_binding:{version:"ctx1", value:"ctx1_req-evidence"},
      public_safe_summary:"reproduce a Pi recovery notification loop",
      received_at:"2026-07-30T10:00:00Z",
      followup_expires_at:$e, reservation_expires_at:$e}' > "$home/request.json"
  jq -n '{type:"pr-merged", project:"firstmate", required_deliverables:["pr_url"], completion_policy:"all-required"}' > "$home/expected.json"
  jq -n '{relation_id:"rel-code", work_ref:{home_id:"main", task_id:"work-evidence"}, role:"fulfills", required:true, generation:1}' > "$home/relation.json"
  ( cd "$home" && tasks-axi public-followup add pf-evidence --request-context-file "$home/request.json" \
      --purpose promised-final --expected-final-file "$home/expected.json" --expires-at "$oexp" >/dev/null &&
    tasks-axi public-followup bind-work pf-evidence --relation-file "$home/relation.json" >/dev/null ) || { echo "seed failed"; return 1; }
  FM_HOME="$home" bash -c ". '$ROOT/bin/fm-x-lib.sh'; fmx_context_registry_set '$home/state' req-evidence discord 1900" || return 1
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PF" register pf-evidence --relation rel-code --work-home main --work-id work-evidence --generation 1 >/dev/null 2>&1
  echo "--- $label: followup_expires_at=$fexp"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PF" pending 2>&1
  echo "  (exit $?)"
  echo
}

scenario "target-clock-relative" "$FOLLOWUP_EXPIRES_AT" "$FOLLOWUP_OBLIGATION_EXPIRES_AT"
scenario "base-hardcoded-2026-08-28" "2026-08-28T01:12:00Z" "2026-10-01T00:00:00Z"

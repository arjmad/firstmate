#!/usr/bin/env bash
# fm-registry-snapshot.sh - emit the Registry-safe local fleet projection.
#
# Usage: fm-registry-snapshot.sh --json
#
# Output contract: `--json` prints one object with schema
# `fm-registry-snapshot.v1`.
# The command is read-only, lock-free, deterministic for a fixed local home and
# FM_REGISTRY_SNAPSHOT_NOW, and never performs GitHub, auth, or network calls.
# It reuses `fm-fleet-snapshot.sh --json` for canonical fleet-state reads, then
# constructs an independent stricter allowlist containing posture classes and
# aggregate counts only.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   status: available, degraded, or unavailable.
#   unavailable_fields: safe field names whose values could not be established.
#   posture.runtime_backend: effective backend class, resolution source, and status.
#   posture.verified_adapters: the verified harness-adapter set and status.
#   posture.delivery_modes: the supported delivery-mode classes and status.
#   posture.x_mode_enabled: boolean opt-in state, or null when unavailable.
#   posture.source_revision: full executing-code-root commit, or null when unavailable.
#   counts.registered_projects: rows in data/projects.md.
#   counts.registered_secondmates: complete registered-table count.
#   counts.active_tasks: structured current In flight rows across readable homes.
#   counts.queued_tasks: structured current Queued rows across readable homes.
#   counts.completed_tasks: structured retained Done rows across readable homes,
#     not all history.
#   counts.unhealthy_endpoints: observed active-task and secondmate endpoints that
#     are absent or whose secondmate agent is dead.
#
# Every posture/count value is paired with available or unavailable status.
# A missing, unreadable, incomplete, or malformed owning input yields null plus
# unavailable; zero is emitted only for a successfully read empty category.
# No task prose, IDs, names, paths, URLs, decisions, credentials, or raw private
# records are copied into this contract, directly or nested.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECT_REGISTRY="$DATA/projects.md"
SECONDMATE_REGISTRY="$DATA/secondmates.md"
X_ENV="$FM_HOME/.env"

usage() {
  cat <<'EOF'
usage: fm-registry-snapshot.sh --json

Print the read-only, local-only Registry projection.
The stable JSON schema is fm-registry-snapshot.v1.
Only safe posture classes and aggregate counts are emitted.
Unknown values are null with status "unavailable" and are named in
unavailable_fields; malformed private content is never echoed.
Set FM_REGISTRY_SNAPSHOT_NOW to a UTC YYYY-MM-DDTHH:MM:SSZ value for a fixed
generation time in deterministic tests.
EOF
}

case "${1:---json}" in
  --json) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf 'fm-registry-snapshot: jq not found\n' >&2
  exit 1
}

NOW=${FM_REGISTRY_SNAPSHOT_NOW:-${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}}
if ! printf '%s' "$NOW" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  file_mode_octal() { stat -f '%Lp' "$1" 2>/dev/null || true; }
else
  file_mode_octal() { stat -c '%a' "$1" 2>/dev/null || true; }
fi

file_has_read_bits() {  # <path>
  local mode
  mode=$(file_mode_octal "$1")
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $((8#$mode & 0444)) -ne 0 ]
}

unavailable_metric='{"value":null,"status":"unavailable"}'

# Resolve the same effective backend class as a new spawn without invoking the
# notice-emitting wrapper or exposing configured text that fails validation.
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
backend_value=unknown
backend_source=unknown
backend_status=unavailable
backend_candidate=
if [ -n "${FM_BACKEND:-}" ]; then
  backend_candidate=$FM_BACKEND
  backend_source=configured
elif [ -e "$CONFIG/backend" ]; then
  backend_source=configured
  if [ -f "$CONFIG/backend" ] && file_has_read_bits "$CONFIG/backend"; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$line" ]; then
        backend_candidate=$line
        break
      fi
    done < "$CONFIG/backend"
    if [ -z "$backend_candidate" ]; then
      backend_source=unknown
    fi
  fi
fi
if [ -z "$backend_candidate" ] && [ "$backend_source" = unknown ]; then
  if fm_backend_detect >/dev/null 2>&1; then
    backend_candidate=$FM_BACKEND_DETECTED
    backend_source=auto
  else
    backend_candidate=tmux
    backend_source=fallback
  fi
fi
if [ -n "$backend_candidate" ] && fm_backend_is_known "$backend_candidate"; then
  backend_value=$backend_candidate
  backend_status=available
fi

adapter_status=unavailable
adapter_values='[]'
adapter_output=$("$SCRIPT_DIR/fm-harness.sh" verified 2>/dev/null) || adapter_output=
if [ -n "$adapter_output" ]; then
  adapter_candidate=$(printf '%s\n' "$adapter_output" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') || adapter_candidate='[]'
  if printf '%s' "$adapter_candidate" | jq -e '
    type == "array" and length > 0 and
    all(.[]; type == "string" and test("^[a-z][a-z0-9-]*$")) and
    length == (unique | length)
  ' >/dev/null 2>&1; then
    adapter_values=$adapter_candidate
    adapter_status=available
  fi
fi

delivery_mode_values='["direct-PR","local-only","no-mistakes"]'

x_status=available
x_value=false
if [ -e "$X_ENV" ]; then
  if [ ! -f "$X_ENV" ] || ! file_has_read_bits "$X_ENV"; then
    x_status=unavailable
    x_value=null
  else
    # shellcheck source=bin/fm-x-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-x-lib.sh"
    x_token=$(fmx_env_get FMX_PAIRING_TOKEN "$X_ENV")
    if [ -n "$x_token" ]; then x_value=true; fi
    unset x_token
  fi
fi

revision_status=unavailable
revision_value=
revision_candidate=$(git -C "$FM_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || revision_candidate=
if printf '%s' "$revision_candidate" | grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$'; then
  revision_value=$revision_candidate
  revision_status=available
fi

projects_metric=$unavailable_metric
if [ -f "$PROJECT_REGISTRY" ] && file_has_read_bits "$PROJECT_REGISTRY"; then
  project_scan=$(awk '
    BEGIN { count=0; malformed=0 }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    /^- / {
      count++
      if ($0 !~ /^- [^[:space:]]+( \[(no-mistakes|direct-PR|local-only)( [+]yolo)?\])? - /) malformed=1
      if (seen[$2]++) malformed=1
      next
    }
    { malformed=1 }
    END { printf "%d %d\n", count, malformed }
  ' "$PROJECT_REGISTRY" 2>/dev/null) || project_scan=
  project_count=${project_scan%% *}
  project_malformed=${project_scan##* }
  case "$project_count:$project_malformed" in
    *[!0-9:]*|:*) ;;
    *:0) projects_metric=$(jq -n --argjson value "$project_count" '{value:$value,status:"available"}') ;;
  esac
fi

# The canonical snapshot owns secondmate aggregation, while this stricter check
# ensures malformed table rows cannot be silently ignored and inferred as zero.
secondmate_registry_status=unavailable
secondmate_registry_count=0
if [ -f "$SECONDMATE_REGISTRY" ] && file_has_read_bits "$SECONDMATE_REGISTRY"; then
  secondmate_scan=$(awk '
    BEGIN { count=0; malformed=0 }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    /^- / {
      count++
      if ($0 !~ /^- [^[:space:]]+ - .*\(home:[[:space:]]*[^;[:space:]][^;]*;.*\)$/) malformed=1
      if (seen[$2]++) malformed=1
      next
    }
    { malformed=1 }
    END { printf "%d %d\n", count, malformed }
  ' "$SECONDMATE_REGISTRY" 2>/dev/null) || secondmate_scan=
  secondmate_registry_count=${secondmate_scan%% *}
  secondmate_malformed=${secondmate_scan##* }
  case "$secondmate_registry_count:$secondmate_malformed" in
    *[!0-9:]*|:*) ;;
    *:0) secondmate_registry_status=available ;;
  esac
fi

snapshot_available=false
fleet_snapshot=$(FM_SNAPSHOT_NOW="$NOW" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) || fleet_snapshot=
if [ -n "$fleet_snapshot" ] && printf '%s' "$fleet_snapshot" | jq -e '
  .schema == "fm-fleet-snapshot.v1" and
  (.backlog | type) == "object" and
  (.tasks | type) == "array" and
  (.secondmate_current | type) == "object"
' >/dev/null 2>&1; then
  snapshot_available=true
fi

registered_secondmates_metric=$unavailable_metric
active_tasks_metric=$unavailable_metric
queued_tasks_metric=$unavailable_metric
completed_tasks_metric=$unavailable_metric
unhealthy_endpoints_metric=$unavailable_metric

if [ "$snapshot_available" = true ]; then
  if [ "$secondmate_registry_status" = available ]; then
    registered_secondmates_metric=$(printf '%s' "$fleet_snapshot" | jq -c \
      --argjson expected "$secondmate_registry_count" '
      .secondmate_current as $s
      | if $s.registry.present == true and
           $s.registry.available == true and
           $s.registry.complete == true and
           all($s.registry.records[]?; .registry_error == null) and
           ($s.total_registered | type) == "number" and
           $s.total_registered == $expected
        then {value:$s.total_registered,status:"available"}
        else {value:null,status:"unavailable"}
        end') || registered_secondmates_metric=$unavailable_metric
  fi

  fleet_backlog_metric() {  # <main-state> <secondmate-count-key>
    printf '%s' "$fleet_snapshot" | jq -c \
      --arg state "$1" \
      --arg count_key "$2" \
      --arg registry_status "$secondmate_registry_status" '
      .secondmate_current as $secondmates
      | if .backlog.present != true or (.backlog.records | type) != "array" then
          {value:null,status:"unavailable"}
        elif any(.backlog.records[]?; .state == $state and .structured != true) then
          {value:null,status:"unavailable"}
        elif $registry_status != "available" or
             $secondmates.truncated != 0 or
             $secondmates.total != $secondmates.shown or
             any($secondmates.records[]?;
               .current.state == "unknown" or (.counts[$count_key] | type) != "number") then
          {value:null,status:"unavailable"}
        else
          {value:(([.backlog.records[]? | select(.state == $state and .structured == true)] | length)
                   + ([$secondmates.records[]?.counts[$count_key]] | add // 0)),
           status:"available"}
        end'
  }
  active_tasks_metric=$(fleet_backlog_metric in_flight active_children) || active_tasks_metric=$unavailable_metric
  queued_tasks_metric=$(fleet_backlog_metric queued queued) || queued_tasks_metric=$unavailable_metric
  completed_tasks_metric=$(fleet_backlog_metric 'done' landed) || completed_tasks_metric=$unavailable_metric

  unhealthy_endpoints_metric=$(printf '%s' "$fleet_snapshot" | jq -c '
    [.tasks[]?
      | select(.kind == "secondmate" or ((.current_state.state // "unknown") != "done" and (.current_state.state // "unknown") != "failed"))] as $observed
    | if any($observed[]; .endpoint.exists == null) then
        {value:null,status:"unavailable"}
      else
        {value:([$observed[] | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")] | length),status:"available"}
      end') || unhealthy_endpoints_metric=$unavailable_metric
fi

jq -n \
  --arg generated "$NOW" \
  --arg backend_value "$backend_value" \
  --arg backend_source "$backend_source" \
  --arg backend_status "$backend_status" \
  --arg adapter_status "$adapter_status" \
  --arg x_status "$x_status" \
  --argjson x_value "$x_value" \
  --arg revision_status "$revision_status" \
  --arg revision_value "$revision_value" \
  --argjson snapshot_available "$snapshot_available" \
  --argjson adapter_values "$adapter_values" \
  --argjson delivery_mode_values "$delivery_mode_values" \
  --argjson registered_projects "$projects_metric" \
  --argjson registered_secondmates "$registered_secondmates_metric" \
  --argjson active_tasks "$active_tasks_metric" \
  --argjson queued_tasks "$queued_tasks_metric" \
  --argjson completed_tasks "$completed_tasks_metric" \
  --argjson unhealthy_endpoints "$unhealthy_endpoints_metric" '
  {
    schema:"fm-registry-snapshot.v1",
    generated:$generated,
    status:"available",
    unavailable_fields:[],
    posture:{
      runtime_backend:{value:$backend_value,source:$backend_source,status:$backend_status},
      verified_adapters:{values:$adapter_values,status:$adapter_status},
      delivery_modes:{values:$delivery_mode_values,status:"available"},
      x_mode_enabled:{value:$x_value,status:$x_status},
      source_revision:{value:(if $revision_value == "" then null else $revision_value end),status:$revision_status}
    },
    counts:{
      registered_projects:$registered_projects,
      registered_secondmates:$registered_secondmates,
      active_tasks:$active_tasks,
      queued_tasks:$queued_tasks,
      completed_tasks:$completed_tasks,
      unhealthy_endpoints:$unhealthy_endpoints
    }
  }
  | .unavailable_fields = ([
      (if .posture.runtime_backend.status != "available" then "posture.runtime_backend" else empty end),
      (if .posture.verified_adapters.status != "available" then "posture.verified_adapters" else empty end),
      (if .posture.x_mode_enabled.status != "available" then "posture.x_mode_enabled" else empty end),
      (if .posture.source_revision.status != "available" then "posture.source_revision" else empty end),
      (.counts | to_entries[] | select(.value.status != "available") | "counts." + .key)
    ] | sort)
  | .status = if $snapshot_available == false then "unavailable"
              elif (.unavailable_fields | length) > 0 then "degraded"
              else "available" end
'

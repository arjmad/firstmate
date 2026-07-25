#!/usr/bin/env bash
# fm-registry-snapshot.sh - emit the bounded Registry operational snapshot.
#
# Usage: fm-registry-snapshot.sh --json
#
# Output contract: `--json` prints one object with schema
# `fm-registry-snapshot.v1`.
# The command is read-only, lock-free, deterministic for fixed local state and
# FM_REGISTRY_SNAPSHOT_NOW, and never performs GitHub, auth, or network calls.
# It reuses `fm-fleet-snapshot.sh --json` for canonical backlog, current-state,
# endpoint, decision, and secondmate-home reads, then adds bounded local project
# and Git evidence without scraping conversations or raw private files.
#
# Top-level sections:
#   schema/generated/status: contract identity, observation time, and availability.
#   limits/omissions/unavailable_fields: explicit output bounds and degradation.
#   provenance: tracked source revision plus mutable code/home locators.
#   configuration: backend, harness routing, delivery, autonomy, and X-mode posture.
#   projects: bounded registered-project rows with local and sanitized remote identity.
#   secondmates: bounded registered rows with runtime, liveness, workload, and freshness.
#   tasks: bounded In flight, Queued, and retained Done rows with reconciled current
#     state, local delivery evidence, one labeled event-history record, and diagnostics.
#   diagnostics: bounded machine-readable consistency findings derived from task rows.
#   counts: aggregate values cross-checked against the detailed section envelopes.
#
# Missing, unreadable, malformed, incomplete, and truncated sources are explicit.
# Chat transcripts, pane captures, full status logs, prompts, briefs, reports, raw
# configuration, credentials, tokens, cookies, and auth payloads are never emitted.
# Locally recorded IDs, concise titles/summaries, branches, PR URLs, and mutable
# local locators are included because this is a trusted local operational contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS_ROOT="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
PROJECT_REGISTRY="$DATA/projects.md"
X_ENV="$FM_HOME/.env"

FM_REGISTRY_PROJECTS=${FM_REGISTRY_PROJECTS:-50}
FM_REGISTRY_SECONDMATES=${FM_REGISTRY_SECONDMATES:-20}
FM_REGISTRY_TASKS_PER_SECTION=${FM_REGISTRY_TASKS_PER_SECTION:-50}
FM_REGISTRY_DIAGNOSTICS=${FM_REGISTRY_DIAGNOSTICS:-100}
FM_REGISTRY_ROUTING_RULES=${FM_REGISTRY_ROUTING_RULES:-50}

usage() {
  cat <<'EOF'
usage: fm-registry-snapshot.sh --json

Print the bounded, read-only, local-only FirstMate Registry contract.
The stable JSON schema is fm-registry-snapshot.v1.
The output contains structured configuration, projects, secondmates, retained task
rows, local delivery evidence, consistency diagnostics, and cross-checked counts.
Private wholesale content and secrets are excluded.
Unknown values use explicit unavailable status; caps are disclosed in omissions.
Set FM_REGISTRY_SNAPSHOT_NOW to UTC YYYY-MM-DDTHH:MM:SSZ for deterministic tests.
Set FM_REGISTRY_PROJECTS, FM_REGISTRY_SECONDMATES,
FM_REGISTRY_TASKS_PER_SECTION, FM_REGISTRY_DIAGNOSTICS, or
FM_REGISTRY_ROUTING_RULES to a non-negative row cap; zero lifts that output cap.
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

validate_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) printf 'fm-registry-snapshot: %s must be a non-negative integer\n' "$1" >&2; exit 2 ;;
  esac
}
validate_bound FM_REGISTRY_PROJECTS "$FM_REGISTRY_PROJECTS"
validate_bound FM_REGISTRY_SECONDMATES "$FM_REGISTRY_SECONDMATES"
validate_bound FM_REGISTRY_TASKS_PER_SECTION "$FM_REGISTRY_TASKS_PER_SECTION"
validate_bound FM_REGISTRY_DIAGNOSTICS "$FM_REGISTRY_DIAGNOSTICS"
validate_bound FM_REGISTRY_ROUTING_RULES "$FM_REGISTRY_ROUTING_RULES"

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
      if [ -n "$line" ]; then backend_candidate=$line; break; fi
    done < "$CONFIG/backend"
    [ -n "$backend_candidate" ] || backend_source=unknown
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

adapter_known() {  # <adapter>
  printf '%s' "$adapter_values" | jq -e --arg value "$1" 'index($value) != null' >/dev/null 2>&1
}

own_harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || own_harness=unknown
adapter_known "$own_harness" || own_harness=unknown
crew_harness=$("$SCRIPT_DIR/fm-harness.sh" crew 2>/dev/null) || crew_harness=unknown
crew_source=detected
if [ -f "$CONFIG/crew-harness" ] && file_has_read_bits "$CONFIG/crew-harness"; then
  crew_setting=$(tr -d '[:space:]' < "$CONFIG/crew-harness" 2>/dev/null || true)
  if [ -n "$crew_setting" ] && [ "$crew_setting" != default ]; then crew_source=configured; fi
fi
crew_status=available
adapter_known "$crew_harness" || { crew_harness=unknown; crew_source=unknown; crew_status=unavailable; }

secondmate_harness=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null) || secondmate_harness=unknown
secondmate_model=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null) || secondmate_model=
secondmate_effort=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null) || secondmate_effort=
secondmate_source=inherited_crew
if [ -f "$CONFIG/secondmate-harness" ] && file_has_read_bits "$CONFIG/secondmate-harness"; then
  secondmate_setting=$(awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { print $1; exit }
  ' "$CONFIG/secondmate-harness" 2>/dev/null || true)
  if [ -n "$secondmate_setting" ] && [ "$secondmate_setting" != default ]; then secondmate_source=configured; fi
fi
secondmate_status=available
adapter_known "$secondmate_harness" || { secondmate_harness=unknown; secondmate_source=unknown; secondmate_status=unavailable; }
case "$secondmate_model" in ''|*[!A-Za-z0-9._:/-]*) secondmate_model= ;; esac
if printf '%s' "$secondmate_model" | grep -Eqi 'gh[pousr]_[A-Za-z0-9_=-]{8,}|sk-[A-Za-z0-9_-]{16,}|(token|password|secret|authorization)[=:]'; then
  secondmate_model=
  secondmate_status=unavailable
fi
case "$secondmate_effort" in ''|low|medium|high|xhigh|max) ;; *) secondmate_effort= ;; esac

crew_dispatch='{"configured":false,"status":"available","complete":true,"rule_count":0,"shown":0,"truncated":0,"rules":[],"default_profile":null}'
crew_dispatch_file="$CONFIG/crew-dispatch.json"
if [ -e "$crew_dispatch_file" ]; then
  crew_dispatch='{"configured":true,"status":"unavailable","complete":false,"rule_count":null,"shown":0,"truncated":null,"rules":[],"default_profile":null}'
  if [ -f "$crew_dispatch_file" ] && file_has_read_bits "$crew_dispatch_file"; then
    crew_dispatch_candidate=$(jq -c --argjson adapters "$adapter_values" \
      --argjson rule_cap "$FM_REGISTRY_ROUTING_RULES" '
      def secret:
        test("gh[pousr]_[A-Za-z0-9_=-]{8,}|sk-[A-Za-z0-9_-]{16,}|(?i)(token|password|secret|authorization)[=:]");
      def valid_profile:
        . as $profile
        | type == "object" and (.harness | type) == "string" and ($adapters | index($profile.harness)) != null
        and ((has("model") | not) or ((.model | type) == "string"
             and (.model | test("^[A-Za-z0-9._:/-]+$") and (secret | not))))
        and ((has("effort") | not) or (.effort | IN("low","medium","high","xhigh","max")));
      def clean_profile:
        {harness:.harness,
         model:(if has("model") then .model[:200] else null end),
         model_truncated:(has("model") and (.model | length) > 200),
         effort:(.effort // null)};
      def profiles:
        if type == "object" then [.] elif type == "array" then . else [] end;
      if type != "object"
         or ((has("rules") and (.rules | type) != "array"))
         or ((has("default") and ((.default | valid_profile) | not)))
         or any(.rules[]?;
              (.when | type) != "string"
              or ((.use | profiles | length) == 0)
              or any((.use | profiles)[]; (valid_profile | not))
              or ((has("select")) and (.select != "quota-balanced")))
      then empty
      else
        . as $config
        | ([($config.rules // []) | to_entries[]
            | {index:.key,selector:(.value.select // "first"),
               profiles:(.value.use | profiles | map(clean_profile))}]) as $all_rules
        | (if $rule_cap == 0 then $all_rules else $all_rules[:$rule_cap] end) as $shown_rules
        | {configured:true,status:"available",complete:(($all_rules | length) == ($shown_rules | length)),
           rule_count:($all_rules | length),shown:($shown_rules | length),
           truncated:(($all_rules | length) - ($shown_rules | length)),rules:$shown_rules,
           default_profile:(if $config | has("default") then ($config.default | clean_profile) else null end)}
      end
    ' "$crew_dispatch_file" 2>/dev/null) || crew_dispatch_candidate=
    if [ -n "$crew_dispatch_candidate" ] \
      && jq -en --argjson candidate "$crew_dispatch_candidate" '$candidate | type == "object"' >/dev/null 2>&1; then
      crew_dispatch=$crew_dispatch_candidate
    fi
  fi
fi

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
    # The token bytes flow only into grep's boolean result and are never captured,
    # retained, redacted, or serialized by this command.
    if fmx_env_get FMX_PAIRING_TOKEN "$X_ENV" | grep -q .; then x_value=true; fi
  fi
fi

revision_status=unavailable
revision_value=
revision_candidate=$(git -C "$FM_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || revision_candidate=
if printf '%s' "$revision_candidate" | grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$'; then
  revision_value=$revision_candidate
  revision_status=available
fi

PROJECT_BASE='{"status":"unavailable","complete":false,"records":[],"reasons":["registry_unavailable"]}'
if [ -f "$PROJECT_REGISTRY" ] && file_has_read_bits "$PROJECT_REGISTRY"; then
  PROJECT_BASE=$(jq -Rn '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def parsed($line; $order):
      (($line | capture("^- (?<key>[^[:space:]]+)(?: \\[(?<options>[^]]+)\\])? - ")?) // null) as $m
      | if $m == null then
          {order:$order,key:null,delivery_mode:null,yolo:null,status:"unavailable",diagnostics:["malformed_project_registry_entry"]}
        else
          (($m.options // "") | split(" ") | map(select(length > 0))) as $options
          | (if ($options | length) == 0 or $options[0] == "+yolo" then "no-mistakes" else $options[0] end) as $mode
          | {order:$order,key:$m.key,
             delivery_mode:(if ($mode == "no-mistakes" or $mode == "direct-PR" or $mode == "local-only") then $mode else null end),
             yolo:($options | index("+yolo") != null),
             status:(if ($mode == "no-mistakes" or $mode == "direct-PR" or $mode == "local-only") then "available" else "unavailable" end),
             diagnostics:(if ($mode == "no-mistakes" or $mode == "direct-PR" or $mode == "local-only") then [] else ["unknown_project_delivery_mode"] end)}
        end;
    reduce inputs as $line
      ({records:[],order:0};
       if ($line | trim) == "" or ($line | test("^[[:space:]]*#")) then .
       else .order += 1 | .records += [parsed($line; .order)] end)
    | .records as $all
    | .records = [$all[] as $r
        | if $r.key != null and ([$all[] | select(.key == $r.key)] | length) > 1
          then $r + {status:"unavailable",diagnostics:($r.diagnostics + ["duplicate_project_key"] | unique)}
          else $r end]
    | del(.order)
    | . + {status:(if any(.records[]?; .status == "unavailable") then "degraded" else "available" end),
           complete:true,reasons:[]}
  ' < "$PROJECT_REGISTRY" 2>/dev/null) || PROJECT_BASE='{"status":"unavailable","complete":false,"records":[],"reasons":["registry_unreadable"]}'
fi

sanitize_remote() {  # <raw-url>; sets REMOTE_KIND/IDENTITY/LOCATOR/STATUS
  local raw=$1 rest host path scheme
  REMOTE_KIND=unknown
  REMOTE_IDENTITY=
  REMOTE_LOCATOR=
  REMOTE_STATUS=unavailable
  case "$raw" in
    http://*|https://*|ssh://*)
      scheme=${raw%%://*}
      rest=${raw#*://}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 0
      host=${host##*@}
      path=${path%%\?*}
      path=${path%.git}
      [ -n "$host" ] && [ -n "$path" ] || return 0
      REMOTE_KIND=$scheme
      REMOTE_IDENTITY="$host/$path"
      REMOTE_LOCATOR="$scheme://$host/$path"
      REMOTE_STATUS=available
      ;;
    *@*:*)
      rest=${raw##*@}
      host=${rest%%:*}
      path=${rest#*:}
      [ "$path" != "$rest" ] || return 0
      path=${path%.git}
      [ -n "$host" ] && [ -n "$path" ] || return 0
      REMOTE_KIND=ssh
      REMOTE_IDENTITY="$host/$path"
      REMOTE_LOCATOR="ssh://$host/$path"
      REMOTE_STATUS=available
      ;;
    file://*)
      REMOTE_KIND='file'
      REMOTE_IDENTITY=local-file-remote
      REMOTE_LOCATOR=$raw
      REMOTE_STATUS=available
      ;;
    /*)
      REMOTE_KIND='file'
      REMOTE_IDENTITY=local-file-remote
      REMOTE_LOCATOR=$raw
      REMOTE_STATUS=available
      ;;
  esac
  if printf '%s' "$REMOTE_IDENTITY$REMOTE_LOCATOR" | grep -Eqi 'gh[pousr]_[A-Za-z0-9_=-]{8,}|sk-[A-Za-z0-9_-]{16,}|(token|password|secret|authorization)[=:]'; then
    REMOTE_KIND=unknown
    REMOTE_IDENTITY=
    REMOTE_LOCATOR=
    REMOTE_STATUS=unavailable
  fi
}

PROJECT_RECORDS='[]'
while IFS= read -r project_row; do
  [ -n "$project_row" ] || continue
  project_key=$(printf '%s' "$project_row" | jq -r '.key // ""')
  project_path=
  project_exists=false
  project_git=false
  project_head=
  local_status=unavailable
  REMOTE_KIND=unknown
  REMOTE_IDENTITY=
  REMOTE_LOCATOR=
  REMOTE_STATUS=unavailable
  if [ -n "$project_key" ]; then
    project_path="$PROJECTS_ROOT/$project_key"
    if [ -d "$project_path" ]; then
      project_exists=true
      local_status=available
      if git -C "$project_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        project_git=true
        project_head=$(git -C "$project_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
        project_remote=$(git -C "$project_path" config --get remote.origin.url 2>/dev/null || true)
        [ -n "$project_remote" ] && sanitize_remote "$project_remote"
        unset project_remote
      fi
    else
      local_status=available
    fi
  fi
  enriched=$(jq -n \
    --argjson base "$project_row" \
    --arg locator "$project_path" \
    --argjson exists "$project_exists" \
    --argjson git_repository "$project_git" \
    --arg head "$project_head" \
    --arg local_status "$local_status" \
    --arg remote_kind "$REMOTE_KIND" \
    --arg remote_identity "$REMOTE_IDENTITY" \
    --arg remote_locator "$REMOTE_LOCATOR" \
    --arg remote_status "$REMOTE_STATUS" '
    $base + {
      local:{locator:(if $locator == "" then null else $locator end),exists:$exists,
             git_repository:$git_repository,
             head_revision:(if $head == "" then null else $head end),status:$local_status},
      remote:{kind:$remote_kind,identity:(if $remote_identity == "" then null else $remote_identity end),
              locator:(if $remote_locator == "" then null else $remote_locator end),status:$remote_status}
    }
    | .status = if .status == "unavailable" then "unavailable"
                elif .local.status == "unavailable" then "degraded"
                else "available" end')
  PROJECT_RECORDS=$(jq -n --argjson rows "$PROJECT_RECORDS" --argjson row "$enriched" '$rows + [$row]')
done <<EOF
$(printf '%s' "$PROJECT_BASE" | jq -c '.records[]?')
EOF
PROJECT_BASE=$(printf '%s' "$PROJECT_BASE" | jq --argjson records "$PROJECT_RECORDS" '.records=$records')

FLEET_AVAILABLE=false
FLEET=$(FM_SNAPSHOT_NOW="$NOW" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) || FLEET=
if [ -n "$FLEET" ] && printf '%s' "$FLEET" | jq -e '
  .schema == "fm-fleet-snapshot.v1" and
  (.backlog | type) == "object" and
  (.tasks | type) == "array" and
  (.secondmate_current | type) == "object"
' >/dev/null 2>&1; then
  FLEET_AVAILABLE=true
else
  FLEET='{"schema":"fm-fleet-snapshot.v1","backlog":{"present":false,"records":[]},"tasks":[],"secondmate_current":{"registry":{"present":false,"available":false,"complete":false,"records":[]},"records":[],"total":null,"shown":0,"truncated":0}}'
fi

TASK_GIT='[]'
while IFS= read -r task_row; do
  [ -n "$task_row" ] || continue
  task_id=$(printf '%s' "$task_row" | jq -r '.id')
  worktree=$(printf '%s' "$task_row" | jq -r '.paths.worktree.path // ""')
  worktree_exists=false
  git_repository=false
  branch=
  revision=
  upstream=
  push_state=unknown
  git_status=unavailable
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    worktree_exists=true
    git_status=available
    if git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git_repository=true
      revision=$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
      branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
      if [ -z "$branch" ]; then
        push_state=detached
      else
        upstream=$(git -C "$worktree" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
        if [ -z "$upstream" ]; then
          push_state=no_upstream
        else
          ahead_behind=$(git -C "$worktree" rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || true)
          behind=${ahead_behind%%[[:space:]]*}
          ahead=${ahead_behind##*[[:space:]]}
          case "$behind:$ahead" in
            0:0) push_state=in_sync ;;
            0:*) push_state=ahead ;;
            *:0) push_state=behind ;;
            *:*) push_state=diverged ;;
            *) push_state=unknown ;;
          esac
        fi
      fi
    fi
  fi
  git_row=$(jq -n \
    --arg id "$task_id" --arg locator "$worktree" --argjson exists "$worktree_exists" \
    --argjson git_repository "$git_repository" --arg branch "$branch" --arg revision "$revision" \
    --arg upstream "$upstream" --arg push_state "$push_state" --arg status "$git_status" '
    {id:$id,locator:(if $locator == "" then null else $locator end),exists:$exists,
     git_repository:$git_repository,branch:(if $branch == "" then null else $branch end),
     revision:(if $revision == "" then null else $revision end),
     upstream:(if $upstream == "" then null else $upstream end),push_state:$push_state,status:$status}')
  TASK_GIT=$(jq -n --argjson rows "$TASK_GIT" --argjson row "$git_row" '$rows + [$row]')
done <<EOF
$(printf '%s' "$FLEET" | jq -c '.tasks[]?')
EOF

PROJECTS_JSON=$(jq -n \
  --argjson base "$PROJECT_BASE" \
  --argjson cap "$FM_REGISTRY_PROJECTS" '
  def redact:
    gsub("gh[pousr]_[A-Za-z0-9_=-]{8,}"; "[redacted]")
    | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
    | gsub("(?i)(bearer[[:space:]]+[^[:space:]]+|(token|password|secret|authorization)[[:space:]]*[:=][[:space:]]*[^[:space:],;]+)"; "[redacted]");
  def safe($n): if . == null then null else (redact | .[0:$n]) end;
  ($base.records | map(
    . as $record
    | .truncated_fields = ([
        if (($record.key // "") | redact | length) > 160 then "key" else empty end,
        if (($record.local.locator // "") | redact | length) > 512 then "local.locator" else empty end,
        if (($record.remote.identity // "") | redact | length) > 320 then "remote.identity" else empty end,
        if (($record.remote.locator // "") | redact | length) > 512 then "remote.locator" else empty end])
    | .key |= safe(160)
    | .local.locator |= safe(512)
    | .remote.identity |= safe(320)
    | .remote.locator |= safe(512)
    | .status = if .status == "available" and (.truncated_fields | length) > 0 then "degraded" else .status end)) as $all
  | ($all | length) as $total
  | (if $cap == 0 then $all else $all[:$cap] end) as $shown
  | ([$all[].truncated_fields[]?] | length) as $field_truncations
  | {status:(if $base.status == "unavailable" then "unavailable"
             elif any($all[]?; .status != "available") then "degraded" else "available" end),
     complete:($base.complete and $field_truncations == 0),total:$total,shown:($shown|length),
     truncated:($total-($shown|length)),records:$shown,
     omissions:([if $total > ($shown|length) then {section:"projects",reason:"record_limit",omitted:($total-($shown|length))} else empty end,
                  if $field_truncations > 0 then {section:"projects",reason:"field_limit",omitted:$field_truncations} else empty end]
                 + [$base.reasons[]? | {section:"projects",reason:.,omitted:null}])}')

SECONDMATES_JSON=$(jq -n \
  --argjson fleet "$FLEET" --argjson adapters "$adapter_values" --arg backend_known "$FM_BACKEND_KNOWN" \
  --argjson cap "$FM_REGISTRY_SECONDMATES" '
  def redact:
    gsub("gh[pousr]_[A-Za-z0-9_=-]{8,}"; "[redacted]")
    | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
    | gsub("(?i)(bearer[[:space:]]+[^[:space:]]+|(token|password|secret|authorization)[[:space:]]*[:=][[:space:]]*[^[:space:],;]+)"; "[redacted]");
  def safe($n): if . == null then null else (redact | .[0:$n]) end;
  def clean_harness($value):
    if ($value | type) == "string" and ($adapters | index($value)) != null then $value else null end;
  def clean_backend($value):
    if ($value | type) == "string" and (($backend_known | split(" ")) | index($value)) != null then $value else null end;
  def clean_model($value):
    if ($value | type) == "string" and ($value | test("^[A-Za-z0-9._:/-]+$"))
       and (($value | redact) == $value) then ($value | safe(200)) else null end;
  def clean_effort($value):
    if ($value | IN("low","medium","high","xhigh","max")) then $value else null end;
  def task_for($id): ([$fleet.tasks[]? | select(.id == $id and .kind == "secondmate")][0] // null);
  def registry_for($id): ([$fleet.secondmate_current.registry.records[]? | select(.id == $id)][0] // null);
  [$fleet.secondmate_current.records[]? as $row
   | task_for($row.id) as $task
   | registry_for($row.id) as $registry
   | (($row.endpoints // []) | map(select(.endpoint.exists == false or .endpoint.agent_alive == "dead")) | length) as $unhealthy_children
   | (($row.endpoints // []) | map(select(.endpoint.exists == null)) | length) as $unknown_children
   | {id:($row.id | safe(160)),
      truncated_fields:([
        if (($row.id // "") | redact | length) > 160 then "id" else empty end,
        if (($registry.scope // "") | redact | length) > 240 then "registry.scope" else empty end,
        if (($row.home // $registry.home // "") | redact | length) > 512 then "registry.home" else empty end,
        if any($registry.projects[]?; (redact | length) > 160) then "registry.projects" else empty end,
        if (($registry.added // "") | redact | length) > 80 then "registry.added" else empty end,
        if clean_model($task.model) != null and ($task.model | length) > 200 then "runtime.model" else empty end]),
      status:(if $registry == null or ($registry.registry_error // null) != null or $row.current.state == "unknown" then "unavailable"
              elif $row.contradiction == true then "degraded" else "available" end),
      registry:{scope:(($registry.scope // null) | safe(240)),
                home:(($row.home // $registry.home // null) | safe(512)),
                projects:($registry.projects // [] | map(safe(160))),
                added:(($registry.added // null) | safe(80)),
                registered:(if $registry != null then $registry.registered else $row.registered end),
                status:(if $registry != null and ($registry.registry_error // null) == null then "available" else "unavailable" end)},
      current:{state:$row.current.state,source:$row.provenance.selected,
               status:(if $row.current.state == "unknown" then "unavailable" else "available" end)},
      runtime:{backend:clean_backend($task.backend),harness:clean_harness($task.harness),
               model:clean_model($task.model),effort:clean_effort($task.effort),
               status:(if $task == null or clean_backend($task.backend) == null or clean_harness($task.harness) == null
                       then "unavailable" else "available" end)},
      endpoint:{exists:(if $task == null then null else $task.endpoint.exists end),
                agent_alive:($task.endpoint.agent_alive // "unknown"),
                status:($task.endpoint.status // "unknown"),observed_at:($task.endpoint.observed_at // null),
                freshness:($task.endpoint.freshness // "unknown")},
      workload:{active_tasks:($row.counts.active_children // null),queued_tasks:($row.counts.queued // null),
                retained_done_tasks:($row.counts.landed // null),endpoint_records:($row.counts.endpoints // null),
                unhealthy_endpoints:$unhealthy_children,unknown_endpoints:$unknown_children,
                status:(if $row.current.state == "unknown"
                           or ($row.counts.active_children | type) != "number"
                           or ($row.counts.queued | type) != "number"
                           or ($row.counts.landed | type) != "number"
                           or ($row.counts.endpoints | type) != "number"
                           or $row.counts.endpoints != (($row.endpoints // []) | length)
                        then "unavailable" else "available" end)},
      freshness:{status:$row.freshness.status,observed_at:$row.freshness.observed_at,
                 age_seconds:$row.freshness.age_seconds},
      completeness:{home_snapshot:($row.provenance.selected == "structured-home"),
                    contradiction:($row.contradiction // false),
                    omitted:($row.omitted // [] | map({surface,count})),
                    status:(if $row.current.state == "unknown" or (($row.omitted // []) | length) > 0
                            then "unavailable" else "available" end)},
      diagnostics:([if ($task != null and $task.endpoint.exists == false) or ($task.endpoint.agent_alive // "") == "dead"
                    then "endpoint_unhealthy" else empty end,
                   if $row.contradiction == true then "secondmate_state_contradiction" else empty end,
                   if ($registry.registry_error // null) != null then "malformed_secondmate_registry_entry" else empty end])}
     | .status = if .status == "available" and ((.truncated_fields | length) > 0 or (.diagnostics | length) > 0)
                 then "degraded" else .status end]
  | . as $all
  | ($fleet.secondmate_current.total // ($all|length)) as $total
  | ($fleet.secondmate_current.total_registered // null) as $total_registered
  | (if $cap == 0 then $all else $all[:$cap] end) as $shown
  | ([$all[].truncated_fields[]?] | length) as $field_truncations
  | {status:(if $fleet.secondmate_current.registry.available != true then "unavailable"
             elif any($all[]?; .status != "available") or ($fleet.secondmate_current.truncated // 0) > 0 then "degraded"
             else "available" end),
     complete:($fleet.secondmate_current.registry.complete == true
               and ($fleet.secondmate_current.truncated // 0) == 0),
     total:$total,total_registered:$total_registered,shown:($shown|length),truncated:($total-($shown|length)),records:$shown,all_records:$all,
     omissions:[if $total > ($shown|length) then {section:"secondmates",reason:"record_limit",omitted:($total-($shown|length))} else empty end,
                if $field_truncations > 0 then {section:"secondmates",reason:"field_limit",omitted:$field_truncations} else empty end,
                if $fleet.secondmate_current.registry.input_truncated == true then {section:"secondmates",reason:"input_limit",omitted:null} else empty end,
                if $fleet.secondmate_current.registry.records_truncated == true then {section:"secondmates",reason:"registry_record_limit",omitted:null} else empty end]}')

TASKS_JSON=$(jq -n \
  --argjson fleet "$FLEET" --argjson adapters "$adapter_values" --arg backend_known "$FM_BACKEND_KNOWN" \
  --argjson projects "$PROJECTS_JSON" \
  --argjson git_rows "$TASK_GIT" \
  --argjson cap "$FM_REGISTRY_TASKS_PER_SECTION" '
  def redact:
    gsub("gh[pousr]_[A-Za-z0-9_=-]{8,}"; "[redacted]")
    | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
    | gsub("(?i)(bearer[[:space:]]+[^[:space:]]+|(token|password|secret|authorization)[[:space:]]*[:=][[:space:]]*[^[:space:],;]+)"; "[redacted]");
  def safe($n): if . == null then null else (redact | .[0:$n]) end;
  def clean_harness($value):
    if ($value | type) == "string" and ($adapters | index($value)) != null then $value else null end;
  def clean_backend($value):
    if ($value | type) == "string" and (($backend_known | split(" ")) | index($value)) != null then $value else null end;
  def clean_model($value):
    if ($value | type) == "string" and ($value | test("^[A-Za-z0-9._:/-]+$"))
       and (($value | redact) == $value) then ($value | safe(200)) else null end;
  def clean_effort($value):
    if ($value | IN("low","medium","high","xhigh","max")) then $value else null end;
  def clean_kind($value):
    if ($value | type) == "string" and ($value | test("^[A-Za-z0-9._:-]+$")) then ($value | safe(80)) else null end;
  def safe_pr_url($value):
    if ($value | type) != "string" then null
    else ((try ($value | capture("^(?<scheme>https?)://(?:[^/@[:space:]]+@)?(?<host>[^/?#[:space:]]+)(?<path>/[^?#[:space:]]*/pull/[0-9]+)$")) catch null) as $url
      | if $url == null then null else (($url.scheme + "://" + $url.host + $url.path) | safe(512)) end)
    end;
  def task_for($id): ([$fleet.tasks[]? | select(.id == $id)][0] // null);
  def scout_report_present($id; $task):
    (($task.hints.scout_report_present // $task.paths.report.present // false) == true)
    or any($fleet.scout_reports[]?; .id == $id);
  def scout_report_recorded($id; $backlog):
    (($backlog.report_path // null) | type) == "string"
    and ($backlog.report_path | endswith("data/" + $id + "/report.md"));
  def git_for($id): ([$git_rows[]? | select(.id == $id)][0] // null);
  def project_for($key): ([$projects.records[]? | select(.key == $key)][0] // null);
  def project_key($backlog; $task):
    if ($backlog.repo // "") != "" then $backlog.repo
    elif ($task.project // "") != "" then ($task.project | split("/") | .[-1])
    else null end;
  def mode_for($task; $project):
    if (($task.mode // "") | IN("no-mistakes","direct-PR","local-only")) then $task.mode
    else ($project.delivery_mode // null) end;
  def yolo_for($task; $project):
    if $task.yolo == "on" then true
    elif $task.yolo == "off" then false
    elif $project == null then null
    else $project.yolo end;
  def current_for($section; $task):
    if $task != null then
      {state:$task.current_state.state,source:$task.current_state.source,
       detail:(if $task.current_state.source == "run-step" then ($task.current_state.detail | safe(200)) else null end),
       observed_at:$task.current_state.observed_at,freshness:$task.current_state.freshness,
       status:(if $task.current_state.state == "unknown" then "unavailable" else "available" end)}
    elif $section == "queued" then {state:"queued",source:"backlog",detail:null,observed_at:null,freshness:"local",status:"available"}
    elif $section == "done" then {state:"done",source:"backlog",detail:null,observed_at:null,freshness:"retained",status:"available"}
    else {state:"unknown",source:"none",detail:null,observed_at:null,freshness:"unknown",status:"unavailable"} end;
  def validation_for($mode; $scout_delivered; $task; $current):
    if $scout_delivered then {required:false,state:"not_required",source:"scout_report",detail:null,status:"available"}
    elif $mode != "no-mistakes" then {required:false,state:"not_required",source:"delivery_mode",detail:null,status:"available"}
    elif $task == null then {required:true,state:"unknown",source:"none",detail:null,status:"unavailable"}
    elif $task.current_state.source == "run-step" then
      {required:true,state:$task.current_state.state,source:"run-step",detail:($task.current_state.detail | safe(200)),status:"available"}
    elif $current.state == "done" then {required:true,state:"missing",source:"none",detail:null,status:"available"}
    else {required:true,state:"not_observed",source:$task.current_state.source,detail:null,status:"available"} end;
  def decision_for($backlog; $task):
    if (($task.hints.open_decisions // []) | length) > 0 then
      ($task.hints.open_decisions[0] | {category:.verb,summary:(.summary | safe(200)),source:"status-fold",status:"available"})
    elif ($backlog.hold_reason // null) != null then
      {category:($backlog.hold_kind // "hold"),summary:($backlog.hold_reason | safe(200)),source:"backlog",status:"available"}
    else {category:null,summary:null,source:"none",status:"available"} end;
  def event_for($task):
    if $task == null or $task.paths.status_log.present != true then
      {category:null,summary:null,role:"event_history",status:"unavailable"}
    else
      {category:($task.paths.status_log.last_event.state // null),
       summary:(($task.paths.status_log.last_event.note // null) | safe(200)),
       role:"event_history",status:"available"} end;
  def make_row($backlog):
    ($backlog.id // null) as $id
    | task_for($id) as $task
    | clean_kind($task.kind // $backlog.kind // null) as $kind
    | ($kind == "scout") as $is_scout
    | scout_report_present($id; $task) as $scout_report_present
    | ($is_scout and scout_report_recorded($id; $backlog) and $scout_report_present) as $scout_delivered
    | git_for($id) as $git
    | project_key($backlog; $task) as $project_key
    | project_for($project_key) as $project
    | mode_for($task; $project) as $mode
    | yolo_for($task; $project) as $yolo
    | current_for($backlog.state; $task) as $current
    | validation_for($mode; $scout_delivered; $task; $current) as $validation
    | (($task.pr.url // $backlog.pr_url // null)) as $pr_url
    | {id:($id | safe(160)),title:(($backlog.title // null) | safe(200)),section:$backlog.state,
       status:(if $backlog.structured != true or $current.status == "unavailable" then "unavailable" else "available" end),
       truncated_fields:([
         if (($id // "") | redact | length) > 160 then "id" else empty end,
         if (($backlog.title // "") | redact | length) > 200 then "title" else empty end,
         if (($project_key // "") | redact | length) > 160 then "project" else empty end,
         if clean_model($task.model) != null and ($task.model | length) > 200 then "runtime.model" else empty end,
         if (($git.locator // $task.paths.worktree.path // "") | redact | length) > 512 then "implementation.worktree" else empty end,
         if (($git.branch // "") | redact | length) > 240 then "implementation.branch" else empty end,
         if (($git.upstream // "") | redact | length) > 320 then "implementation.upstream" else empty end,
         if safe_pr_url($pr_url) != null and (($pr_url // "") | length) > 512
           then "delivery_evidence.pr.url" else empty end,
         if $task.current_state.source == "run-step" and (($task.current_state.detail // "") | redact | length) > 200
           then "current.detail" else empty end,
         if ((($task.hints.open_decisions[0].summary // $backlog.hold_reason // "") | redact | length) > 200)
           then "decision.summary" else empty end,
         if (($task.paths.status_log.last_event.note // "") | redact | length) > 200
           then "event_history.summary" else empty end]),
       project:($project_key | safe(160)),kind:$kind,
       delivery:{mode:$mode,yolo:$yolo,
                 source:(if ($task.mode // "") != "" then "task_metadata" elif $project != null then "project_registry" else "unknown" end),
                 status:(if $mode == null or $yolo == null then "unavailable" else "available" end)},
       current:$current,
       runtime:{harness:clean_harness($task.harness),model:clean_model($task.model),
                effort:clean_effort($task.effort),backend:clean_backend($task.backend),
                status:(if $task == null or clean_harness($task.harness) == null or clean_backend($task.backend) == null
                        then "unavailable" else "available" end)},
       endpoint:{exists:(if $task == null then null else $task.endpoint.exists end),
                 agent_alive:($task.endpoint.agent_alive // "unknown"),
                 status:($task.endpoint.status // "unknown"),observed_at:($task.endpoint.observed_at // null),
                 freshness:($task.endpoint.freshness // "unknown")},
       implementation:{worktree:(($git.locator // $task.paths.worktree.path // null) | safe(512)),
                       exists:($git.exists // false),git_repository:($git.git_repository // false),
                       branch:(($git.branch // null) | safe(240)),revision:($git.revision // null),
                       upstream:(($git.upstream // null) | safe(320)),push_state:($git.push_state // "unknown"),
                       status:($git.status // "unavailable")},
       delivery_evidence:{validation:$validation,
                          pr:{url:safe_pr_url($pr_url),
                              head:(($task.pr.head // null)
                                    | if . != null and test("^[0-9a-f]{40}([0-9a-f]{24})?$") then . else null end),
                              source:(if ($task.pr.url // null) != null then $task.pr.source
                                      elif ($backlog.pr_url // null) != null then "backlog" else "absent" end),
                              status:(if $pr_url != null and safe_pr_url($pr_url) == null then "unavailable" else "available" end)}},
       decision:decision_for($backlog; $task),
       event_history:event_for($task),
       diagnostics:[]}
    # Scout reports are the only implemented no-PR terminal contract, and a bare
    # kind=scout annotation is never trusted on its own: the durable backlog record
    # must also link data/<id>/report.md and that report must exist. A stale scout
    # annotation left behind by a promoted ship therefore stays flagged.
    # A future kind=ops exemption should first define its required durable completion evidence.
    | .diagnostics = ([
        if $backlog.structured != true then "malformed_backlog_record" else empty end,
        if $backlog.state == "in_flight" and $task == null then "in_flight_without_task_record" else empty end,
        if $backlog.state == "in_flight" and ((.endpoint.exists == false) or (.endpoint.agent_alive == "dead")) then "endpoint_unhealthy" else empty end,
        if .delivery_evidence.pr.status == "unavailable" then "invalid_local_pr_evidence" else empty end,
        if .current.state == "done" and $is_scout and $scout_report_present != true
          then "reported_done_without_scout_report" else empty end,
        if .current.state == "done" and $scout_delivered != true and (.delivery.mode == "no-mistakes" or .delivery.mode == "direct-PR") and .delivery_evidence.pr.url == null
          then "reported_done_without_required_pr" else empty end,
        if .current.state == "done" and $scout_delivered != true and .delivery.mode == "no-mistakes" and .delivery_evidence.validation.state == "missing"
          then "validation_missing" else empty end,
        if .current.state == "done" and $scout_delivered != true and (.delivery.mode == "no-mistakes" or .delivery.mode == "direct-PR")
           and (.implementation.push_state == "no_upstream" or .implementation.push_state == "ahead" or .implementation.push_state == "diverged")
          then "branch_not_pushed" else empty end,
        if $backlog.state == "done" and ($task.current_state.state // "done") != "done" and ($task.current_state.state // "done") != "failed"
          then "retained_done_with_nonterminal_worker" else empty end
      ] | unique)
    | .status = if .status == "unavailable" or (.diagnostics | index("malformed_backlog_record")) != null then "unavailable"
                elif (.diagnostics | length) > 0 or (.truncated_fields | length) > 0 then "degraded" else .status end;
  def section($state; $name):
    ([$fleet.backlog.records[]? | select(.state == $state) | make_row(.)]) as $all
    | (if $cap == 0 then $all else $all[:$cap] end) as $shown
    | ([$all[].truncated_fields[]?] | length) as $field_truncations
    | {name:$name,status:(if $fleet.backlog.present != true then "unavailable"
                         elif any($all[]?; .status != "available") then "degraded" else "available" end),
       complete:($fleet.backlog.present == true and all($all[]?; .status != "unavailable")),
       total:($all|length),shown:($shown|length),truncated:(($all|length)-($shown|length)),
       records:$shown,all_records:$all,
       omissions:[if ($all|length) > ($shown|length) then {section:("tasks."+$name),reason:"record_limit",omitted:(($all|length)-($shown|length))} else empty end,
                  if $field_truncations > 0 then {section:("tasks."+$name),reason:"field_limit",omitted:$field_truncations} else empty end]};
  {in_flight:section("in_flight";"in_flight"),
   queued:section("queued";"queued"),
   retained_done:section("done";"retained_done")}
  | .status = if (.in_flight.status == "unavailable" and .queued.status == "unavailable" and .retained_done.status == "unavailable") then "unavailable"
              elif (.in_flight.status != "available" or .queued.status != "available" or .retained_done.status != "available") then "degraded"
              else "available" end
  | .complete = (.in_flight.complete and .queued.complete and .retained_done.complete)
  | .omissions = (.in_flight.omissions + .queued.omissions + .retained_done.omissions)')

DIAGNOSTICS_JSON=$(jq -n \
  --argjson tasks "$TASKS_JSON" \
  --argjson secondmates "$SECONDMATES_JSON" \
  --argjson cap "$FM_REGISTRY_DIAGNOSTICS" '
  def severity($code):
    if $code == "reported_done_without_required_pr" or $code == "reported_done_without_scout_report"
       or $code == "validation_missing" or $code == "branch_not_pushed" or $code == "endpoint_unhealthy"
      then "warning" else "info" end;
  ([ $tasks.in_flight.all_records[], $tasks.queued.all_records[], $tasks.retained_done.all_records[]
      | . as $row | $row.diagnostics[]? | {scope:"task",record_id:$row.id,code:.,severity:severity(.)} ]
   + [ $secondmates.all_records[]? | . as $row | $row.diagnostics[]?
       | {scope:"secondmate",record_id:$row.id,code:.,severity:severity(.)} ]) as $all
  | ($tasks.in_flight.status != "unavailable" and $tasks.queued.status != "unavailable"
     and $tasks.retained_done.status != "unavailable" and $secondmates.complete == true) as $source_complete
  | (if $cap == 0 then $all else $all[:$cap] end) as $shown
  | {status:(if $source_complete then "available" else "unavailable" end),
     complete:($source_complete and (($all|length)==($shown|length))),
     total:(if $source_complete then ($all|length) else null end),observed_total:($all|length),shown:($shown|length),
     truncated:(($all|length)-($shown|length)),
     by_code:(reduce $all[] as $d ({}; .[$d.code] = ((.[$d.code] // 0) + 1))),records:$shown,
     omissions:[if ($all|length) > ($shown|length) then {section:"diagnostics",reason:"record_limit",omitted:(($all|length)-($shown|length))} else empty end]}')

CONFIGURATION_JSON=$(jq -n \
  --arg backend_value "$backend_value" --arg backend_source "$backend_source" --arg backend_status "$backend_status" \
  --arg adapter_status "$adapter_status" --argjson adapters "$adapter_values" \
  --arg own_harness "$own_harness" --arg crew_harness "$crew_harness" --arg crew_source "$crew_source" --arg crew_status "$crew_status" \
  --arg secondmate_harness "$secondmate_harness" --arg secondmate_model "$secondmate_model" --arg secondmate_effort "$secondmate_effort" \
  --arg secondmate_source "$secondmate_source" --arg secondmate_status "$secondmate_status" \
  --argjson crew_dispatch "$crew_dispatch" \
  --arg x_status "$x_status" --argjson x_value "$x_value" --argjson projects "$PROJECTS_JSON" '
  {runtime_backend:{value:$backend_value,source:$backend_source,status:$backend_status},
   verified_adapters:{values:$adapters,status:$adapter_status},
   routing:{primary:{harness:$own_harness,source:"detected",status:(if $own_harness == "unknown" then "unavailable" else "available" end)},
            crew:{harness:$crew_harness,source:$crew_source,status:$crew_status},
            secondmate:{harness:$secondmate_harness,
                        model:(if $secondmate_model == "" then null else $secondmate_model end),
                        effort:(if $secondmate_effort == "" then null else $secondmate_effort end),
                        source:$secondmate_source,status:$secondmate_status},
            crew_dispatch:$crew_dispatch},
   delivery:{supported_modes:["direct-PR","local-only","no-mistakes"],
             observed_modes:([$projects.records[].delivery_mode | select(. != null)] | unique),
             status:$projects.status},
   autonomy:{project_yolo_on:([$projects.records[] | select(.yolo == true)] | length),
             project_yolo_off:([$projects.records[] | select(.yolo == false)] | length),
             status:$projects.status},
   x_mode_enabled:{value:$x_value,status:$x_status}}
  | .status = if any([.runtime_backend.status,.verified_adapters.status,.routing.primary.status,.routing.crew.status,.routing.secondmate.status,.routing.crew_dispatch.status,.delivery.status,.autonomy.status,.x_mode_enabled.status][]; . == "unavailable")
              then "degraded" else "available" end')

COUNTS_JSON=$(jq -n \
  --argjson projects "$PROJECTS_JSON" --argjson secondmates "$SECONDMATES_JSON" \
  --argjson tasks "$TASKS_JSON" --argjson diagnostics "$DIAGNOSTICS_JSON" '
  def metric($value; $status; $source): {value:$value,status:$status,source:$source};
  def workload_sum($key): [$secondmates.all_records[]?.workload[$key] | select(type == "number")] | add // 0;
  def workload_complete: $secondmates.complete == true and all($secondmates.all_records[]?; .workload.status == "available");
  def task_endpoint_rows: [$tasks.in_flight.all_records[]?];
  def task_endpoint_unknown: any(task_endpoint_rows[]?; .endpoint.exists == null);
  def task_unhealthy: [task_endpoint_rows[]? | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")] | length;
  def secondmate_unhealthy:
    [$secondmates.all_records[]? | ((if .endpoint.exists == false or .endpoint.agent_alive == "dead" then 1 else 0 end) + (.workload.unhealthy_endpoints // 0))] | add // 0;
  {registered_projects:metric((if $projects.status == "unavailable" then null else $projects.total end);
                              (if $projects.status == "unavailable" then "unavailable" else "available" end);"projects.total"),
   registered_secondmates:metric((if $secondmates.complete != true or ($secondmates.total_registered | type) != "number" then null
                                  else $secondmates.total_registered end);
                                 (if $secondmates.complete != true or ($secondmates.total_registered | type) != "number"
                                  then "unavailable" else "available" end);"secondmates.total_registered"),
   active_tasks:metric((if $tasks.in_flight.status == "unavailable" or (workload_complete|not) then null
                        else $tasks.in_flight.total + workload_sum("active_tasks") end);
                       (if $tasks.in_flight.status == "unavailable" or (workload_complete|not) then "unavailable" else "available" end);
                       "tasks.in_flight.total + secondmates.workload.active_tasks"),
   queued_tasks:metric((if $tasks.queued.status == "unavailable" or (workload_complete|not) then null
                        else $tasks.queued.total + workload_sum("queued_tasks") end);
                       (if $tasks.queued.status == "unavailable" or (workload_complete|not) then "unavailable" else "available" end);
                       "tasks.queued.total + secondmates.workload.queued_tasks"),
   retained_done_tasks:metric((if $tasks.retained_done.status == "unavailable" or (workload_complete|not) then null
                               else $tasks.retained_done.total + workload_sum("retained_done_tasks") end);
                              (if $tasks.retained_done.status == "unavailable" or (workload_complete|not) then "unavailable" else "available" end);
                              "tasks.retained_done.total + secondmates.workload.retained_done_tasks"),
   unhealthy_endpoints:metric((if task_endpoint_unknown or (workload_complete|not) then null else task_unhealthy + secondmate_unhealthy end);
                              (if task_endpoint_unknown or (workload_complete|not) then "unavailable" else "available" end);
                              "task and secondmate endpoint summaries"),
   diagnostics:metric($diagnostics.total;$diagnostics.status;"diagnostics.total"),
   diagnostics_by_code:$diagnostics.by_code}')

FINAL=$(jq -n \
  --arg generated "$NOW" --argjson fleet_available "$FLEET_AVAILABLE" \
  --arg revision "$revision_value" --arg revision_status "$revision_status" \
  --arg fm_root "$FM_ROOT" --arg fm_home "$FM_HOME" \
  --argjson configuration "$CONFIGURATION_JSON" --argjson projects "$PROJECTS_JSON" \
  --argjson secondmates "$SECONDMATES_JSON" --argjson tasks "$TASKS_JSON" \
  --argjson diagnostics "$DIAGNOSTICS_JSON" --argjson counts "$COUNTS_JSON" \
  --argjson project_cap "$FM_REGISTRY_PROJECTS" --argjson secondmate_cap "$FM_REGISTRY_SECONDMATES" \
  --argjson task_cap "$FM_REGISTRY_TASKS_PER_SECTION" --argjson diagnostic_cap "$FM_REGISTRY_DIAGNOSTICS" \
  --argjson routing_cap "$FM_REGISTRY_ROUTING_RULES" '
  def redact:
    gsub("gh[pousr]_[A-Za-z0-9_=-]{8,}"; "[redacted]")
    | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
    | gsub("(?i)(bearer[[:space:]]+[^[:space:]]+|(token|password|secret|authorization)[[:space:]]*[:=][[:space:]]*[^[:space:],;]+)"; "[redacted]");
  def safe_locator: redact | .[0:512];
  {schema:"fm-registry-snapshot.v1",generated:$generated,status:"available",
   limits:{projects:$project_cap,secondmates:$secondmate_cap,tasks_per_section:$task_cap,
           diagnostics:$diagnostic_cap,routing_rules:$routing_cap},
   omissions:($projects.omissions + $secondmates.omissions + $tasks.omissions + $diagnostics.omissions
              + [if $configuration.routing.crew_dispatch.truncated > 0
                 then {section:"configuration.routing.crew_dispatch",reason:"record_limit",
                       omitted:$configuration.routing.crew_dispatch.truncated}
                 else empty end]),
   unavailable_fields:[],
   provenance:{source:{revision:(if $revision == "" then null else $revision end),
                       locator:($fm_root|safe_locator),locator_kind:"mutable_local",status:$revision_status},
               home:{locator:($fm_home|safe_locator),locator_kind:"mutable_local",status:"available"},
               canonical_snapshot:{schema:"fm-fleet-snapshot.v1",status:(if $fleet_available then "available" else "unavailable" end)}},
   configuration:$configuration,projects:($projects|del(.all_records)),
   secondmates:($secondmates|del(.all_records)),
   tasks:($tasks|del(.in_flight.all_records,.queued.all_records,.retained_done.all_records)),
   diagnostics:$diagnostics,counts:$counts}
  | .unavailable_fields = ([
      (if .provenance.source.status != "available" then "provenance.source" else empty end),
      (if .provenance.canonical_snapshot.status != "available" then "provenance.canonical_snapshot" else empty end),
      (if .configuration.status != "available" then "configuration" else empty end),
      (if .projects.status == "unavailable" then "projects" else empty end),
      (if .secondmates.status == "unavailable" then "secondmates" else empty end),
      (if .tasks.status == "unavailable" then "tasks" else empty end),
      (.counts | to_entries[] | select(.key != "diagnostics_by_code" and .value.status != "available") | "counts." + .key)
    ] | unique | sort)
  | .status = if $fleet_available == false then "unavailable"
              elif (.unavailable_fields|length)>0 or (.omissions|length)>0
                   or .configuration.status != "available" or .projects.status != "available"
                   or .secondmates.status != "available" or .tasks.status != "available"
                   or .diagnostics.total > 0 then "degraded"
              else "available" end')

if ! printf '%s' "$FINAL" | jq -e 'type == "object" and .schema == "fm-registry-snapshot.v1"' >/dev/null 2>&1; then
  printf 'fm-registry-snapshot: failed to assemble fm-registry-snapshot.v1 output\n' >&2
  exit 1
fi
printf '%s\n' "$FINAL"

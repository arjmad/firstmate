#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <task-id|label>  (only a name built from the exact
#     task id is reclaimable by teardown-task; a plain label is standalone)
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#   fm-herdr-lab.sh teardown-task <task-id>
#   fm-herdr-lab.sh reap [--apply]
#   fm-herdr-lab.sh tripwires <task-id>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command combines a short sanitized stem of its argument with a
# deterministic token for the owning home plus that complete argument, then
# appends process/random suffixes. The token lets task teardown target exact
# ownership without collisions between truncated ids, so a lab a task must
# later reclaim has to be named with that task's exact id under the same
# effective home. Binding the token to the home keeps a second Firstmate home
# running a task with the SAME id (a secondmate home, a handed-off task) from
# ever matching - and destroying - this home's live lab session, and vice
# versa; the tripwire directory is per-UID and shared across homes, so the
# name is the only home boundary these records have.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
# Reap is the only cross-task command. It is a dry run unless --apply is given,
# and it destroys a session only when the effective FM_HOME positively proves
# ownership: exactly one task record in this home names the session and that
# record's recovery-grade agent state is dead or missing. A session this home
# holds no task record for is unproven, never dead. Every ambiguous, unreadable,
# unverified, or foreign session is left running and reported by exact name.
# Reap never enumerates other Firstmate homes.
set -u

# shellcheck source=bin/fm-herdr-env-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-herdr-env-lib.sh"

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

# Every herdr call is scrubbed: a lab host auto-started here inherits this
# process's environment and passes it to every lab pane, so an unscrubbed call
# would propagate CLAUDE_CODE_CHILD_SESSION and disable transcript saving in
# Claude sessions launched under those panes (bin/fm-herdr-env-lib.sh).
fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" fm_herdr_scrubbed_exec herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions snapshot
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires exactly one running default session"
    return 1
  }
  printf '%s\n' "$snapshot"
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  fm_herdr_lab_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

fm_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  fm_herdr_lab_validate_name "$name" || return 1
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(fm_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

fm_herdr_lab_stop() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  sleep 0.5
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_label() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf '%s\n' "$label"
}

# The home half of the ownership token: the resolved state root, physical when
# it exists, which is the same identity bin/fm-teardown.sh forwards through
# FM_HOME/FM_STATE_OVERRIDE when it reclaims a task's labs.
fm_herdr_lab_home_key() {
  local root
  root=$(fm_herdr_lab_state_root)
  if [ -d "$root" ]; then
    root=$(cd "$root" && pwd -P) || return 1
  fi
  printf '%s\n' "$root"
}

fm_herdr_lab_task_token() { # <task-id>
  local home token
  home=$(fm_herdr_lab_home_key) || return 1
  token=$(printf '%s\n%s' "$home" "$1" | cksum | cut -d ' ' -f1) || return 1
  printf '%s\n' "${token:0:8}"
}

# The single derivation shared by session naming and task-scoped teardown. Both
# must agree byte for byte or durable teardown silently matches nothing.
fm_herdr_lab_task_stem() { # <task-id>
  local label
  label=$(fm_herdr_lab_label "${1:-lab}") || return 1
  label=${label:0:10}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf '%s\n' "$label"
}

fm_herdr_lab_name() { # <task-id|label>
  local task_id=${1:-lab} label token
  label=$(fm_herdr_lab_task_stem "$task_id") || return 1
  token=$(fm_herdr_lab_task_token "$task_id") || return 1
  printf 'fm-lab-%s-%s-%s-%s\n' "$label" "$token" "$$" "$RANDOM"
}

fm_herdr_lab_task_id_valid() { # <task-id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_herdr_lab_task_prefix() { # <task-id>
  local label token
  fm_herdr_lab_task_id_valid "${1:-}" || {
    fm_herdr_lab_error "invalid task id '${1:-}'"
    return 1
  }
  label=$(fm_herdr_lab_task_stem "$1") || return 1
  token=$(fm_herdr_lab_task_token "$1") || return 1
  printf 'fm-lab-%s-%s-' "$label" "$token"
}

fm_herdr_lab_legacy_task_prefix() { # <task-id>
  local label
  label=$(fm_herdr_lab_label "$1") || return 1
  printf 'fm-lab-%s-' "$label"
}

fm_herdr_lab_task_tripwires() { # <task-id>
  local prefix state_dir tripwire
  prefix=$(fm_herdr_lab_task_prefix "$1") || return 1
  state_dir=$(fm_herdr_lab_state_dir)
  for tripwire in "$state_dir/$prefix"*.fleet-state.json; do
    [ -e "$tripwire" ] || [ -L "$tripwire" ] || continue
    printf '%s\n' "$tripwire"
  done
}

fm_herdr_lab_teardown_task() { # <task-id>
  local task_id=$1 tripwire session
  fm_herdr_lab_task_id_valid "$task_id" || {
    fm_herdr_lab_error "invalid task id '$task_id'"
    return 1
  }
  while IFS= read -r tripwire; do
    [ -n "$tripwire" ] || continue
    if [ ! -f "$tripwire" ] || [ -L "$tripwire" ]; then
      fm_herdr_lab_error "refusing unsafe lab ownership record '$tripwire'"
      return 1
    fi
    session=${tripwire##*/}
    session=${session%.fleet-state.json}
    fm_herdr_lab_teardown "$session" || {
      fm_herdr_lab_error "lab ownership record remains: $tripwire"
      return 1
    }
  done <<EOF
$(fm_herdr_lab_task_tripwires "$task_id")
EOF
  return 0
}

fm_herdr_lab_state_root() {
  printf '%s' "${FM_STATE_OVERRIDE:-${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/state}"
}

fm_herdr_lab_load_backend() {
  local script_dir
  [ "${FM_HERDR_LAB_BACKEND_LOADED:-0}" = 1 ] && return 0
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$script_dir/fm-backend.sh" || return 1
  FM_HERDR_LAB_BACKEND_LOADED=1
}

fm_herdr_lab_meta_agent_state() { # <meta>
  local meta=$1 backend target
  fm_herdr_lab_load_backend || { printf 'unreadable\n'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'unreadable\n'; return 0; }
  fm_backend_agent_state "$backend" "$target"
}

# Ownership verdict for one lab session, judged only against the effective
# FM_HOME's own task records. Prints exactly one of:
#   live     - a task record claiming the session has a live agent.
#   reapable - exactly one task record in this home claims the session and its
#              recovery-grade state is dead or missing.
#   unproven - everything else, including a session no task record here claims.
# Only `reapable` licenses destruction; absence of a record is never death.
# The deterministic home-scoped task token in a token-bearing session name is
# the authoritative claim: when any task record's token prefix matches,
# ownership is decided from those records alone, and a session minted by a
# DIFFERENT home for the same task id carries a different token and is never
# claimed. The pre-token label prefix is consulted only as a fallback for
# legacy-shaped sessions no token prefix claims, where truncated labels can
# leave two records claiming one session and the verdict stays unproven; it
# never claims a token-bearing name, whose ownership only its exact home-scoped
# token may decide.
fm_herdr_lab_session_verdict() { # <session>
  local session=$1 state_root meta task_id prefix legacy_prefix agent_state claim rest
  local token_matches=0 token_state='' legacy_matches=0 legacy_state='' matches state
  state_root=$(fm_herdr_lab_state_root)
  { [ -d "$state_root" ] && [ ! -L "$state_root" ]; } || { printf 'unproven\n'; return 0; }
  for meta in "$state_root"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      printf 'unproven\n'
      return 0
    fi
    task_id=${meta##*/}
    task_id=${task_id%.meta}
    prefix=$(fm_herdr_lab_task_prefix "$task_id" 2>/dev/null) || { printf 'unproven\n'; return 0; }
    legacy_prefix=$(fm_herdr_lab_legacy_task_prefix "$task_id") || { printf 'unproven\n'; return 0; }
    case "$session" in
      "$prefix"*) claim=token ;;
      "$legacy_prefix"*)
        rest=${session#"$legacy_prefix"}
        if [[ "$rest" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]]; then
          continue
        fi
        claim=legacy
        ;;
      *) continue ;;
    esac
    agent_state=$(fm_herdr_lab_meta_agent_state "$meta") || agent_state=unreadable
    if [ "$agent_state" = alive ]; then
      printf 'live\n'
      return 0
    fi
    if [ "$claim" = token ]; then
      token_matches=$((token_matches + 1))
      token_state=$agent_state
    else
      legacy_matches=$((legacy_matches + 1))
      legacy_state=$agent_state
    fi
  done
  if [ "$token_matches" -gt 0 ]; then
    matches=$token_matches
    state=$token_state
  else
    matches=$legacy_matches
    state=$legacy_state
  fi
  [ "$matches" -eq 1 ] || { printf 'unproven\n'; return 0; }
  case "$state" in
    dead|missing) printf 'reapable\n' ;;
    *) printf 'unproven\n' ;;
  esac
}

fm_herdr_lab_reap() { # [--apply]
  local mode=${1:-} sessions names name verdict tripwire owned=''
  case "$mode" in
    '') mode=dry-run ;;
    --apply) mode=apply ;;
    *) fm_herdr_lab_error "reap accepts only --apply"; return 2 ;;
  esac
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  fm_herdr_lab_load_backend || {
    fm_herdr_lab_error "cannot load the recovery-grade liveness contract for lab reaping"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list default 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions for lab reaping"
    return 1
  }
  names=$(printf '%s' "$sessions" | jq -r '.sessions[]? | select(.name | startswith("fm-lab-")) | .name' 2>/dev/null) || {
    fm_herdr_lab_error "cannot parse Herdr sessions for lab reaping"
    return 1
  }

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    verdict=unproven
    if fm_herdr_lab_validate_name "$name" 2>/dev/null; then
      verdict=$(fm_herdr_lab_session_verdict "$name")
    fi
    if [ "$verdict" = live ]; then
      printf 'keep live task lab: %s\n' "$name"
      continue
    fi
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    if [ "$verdict" != reapable ] || [ ! -f "$tripwire" ] || [ -L "$tripwire" ]; then
      printf 'leave unproven lab: %s\n' "$name"
      continue
    fi
    printf '%s stale task lab: %s\n' "$mode" "$name"
    owned="$owned$name"$'\n'
  done <<EOF
$names
EOF

  if [ "$mode" = dry-run ]; then
    return 0
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
      fm_herdr_lab_error "ownership changed during reap for '$name'"
      return 1
    }
    fm_herdr_lab_teardown "$name" || return 1
    printf 'removed stale task lab: %s\n' "$name"
  done <<EOF
$owned
EOF
}

fm_herdr_lab_usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    teardown-task)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown_task "$2"
      ;;
    reap)
      [ "$#" -le 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_reap "${2:-}"
      ;;
    tripwires)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_task_tripwires "$2"
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi

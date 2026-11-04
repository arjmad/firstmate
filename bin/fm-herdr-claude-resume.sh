#!/usr/bin/env bash
# fm-herdr-claude-resume.sh - report a Firstmate-launched Claude agent's full
# launch as its Herdr resume command, so a Herdr server restart resumes the
# conversation on the same account and contract it was launched with.
#
# Why: with `[session] resume_agents_on_restore` on (Herdr's default), a
# restored pane re-runs the agent from what was reported for it. Herdr's own
# Claude integration reports only the session id, from which Herdr builds a
# bare `claude --resume <id>` in the pane's login shell: no CLAUDE_CONFIG_DIR
# account pin, no --settings hooks, no permission mode, model, effort,
# --add-dir grant or --name. Herdr also accepts a resume command reported by
# the integration that holds the pane, and prefers it over the bare one
# (docs/herdr-backend.md "Native agent resume").
#
# Usage:
#
#   fm-herdr-claude-resume.sh hook <resume-file>
#       Claude Code SessionStart hook; the hook payload arrives on stdin.
#       Outside a Herdr pane, for a subagent, for a payload without a usable
#       session id, or for an unusable resume file it does nothing. Otherwise
#       it returns at once and, detached, sends `report` after each delay in
#       FM_HERDR_RESUME_DELAYS (seconds, space separated, default "1 5"), so
#       its report follows the one Herdr's own hook sends for the same event:
#       Herdr applies a report only when its --seq is newer than the last one
#       from that source, and both hooks run in parallel.
#       Always exits 0, so it can never block or fail Claude's startup.
#
#   fm-herdr-claude-resume.sh report <resume-file> <session-id> [<start-source>]
#       Send one report for the pane in HERDR_PANE_ID through HERDR_BIN_PATH
#       (or `herdr` on PATH), reached through the pane's HERDR_SOCKET_PATH:
#       source herdr:claude, agent claude, the session id, and the resume
#       command `sh <resume-file> <session-id>`. Exits nonzero when the report
#       could not be sent; Herdr answers success without applying a report
#       that is not newer, so success does not prove it was applied.
#
# The resume file is written by bin/fm-spawn.sh as state/<id>.claude-resume.sh:
# the agent's own launch with the launch-brief argument replaced by
# `--resume "$1"`. Herdr types the resume command into the pane's shell, so
# it must start with a plain command name and carry no apostrophe or control
# character; `sh` plus an absolute path and a session id meets that.
set -u

fm_herdr_resume_usable_file() {  # <resume-file>
  local file=${1-}
  case "$file" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$file" in
    *\'* | *[[:cntrl:]]*) return 1 ;;
  esac
  [ -f "$file" ] && [ -r "$file" ]
}

fm_herdr_resume_usable_session() {  # <session-id>
  [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

fm_herdr_resume_in_pane() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ]
}

# Nanoseconds since the epoch, comparable with the time_ns() Herdr's own hook
# uses as its --seq. EPOCHREALTIME is a bash builtin; its separator follows the
# locale, so keep only the digits.
fm_herdr_resume_now_ns() {
  local raw=${EPOCHREALTIME:-}
  raw=${raw//[!0-9]/}
  [ -n "$raw" ] || return 1
  printf '%s000' "$raw"
}

fm_herdr_resume_report() {  # <resume-file> <session-id> [<start-source>]
  local file=${1-} sid=${2-} start_source=${3-} herdr_bin seq
  fm_herdr_resume_in_pane || return 1
  fm_herdr_resume_usable_file "$file" || return 1
  fm_herdr_resume_usable_session "$sid" || return 1
  herdr_bin=${HERDR_BIN_PATH:-}
  [ -n "$herdr_bin" ] && [ -x "$herdr_bin" ] || herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  seq=$(fm_herdr_resume_now_ns) || return 1
  local -a args=(pane report-agent-session "$HERDR_PANE_ID"
    --source herdr:claude --agent claude --seq "$seq" --agent-session-id "$sid")
  [[ "$start_source" =~ ^[a-z]{1,32}$ ]] && args+=(--session-start-source "$start_source")
  "$herdr_bin" "${args[@]}" -- sh "$file" "$sid" >/dev/null
}

fm_herdr_resume_hook() {  # <resume-file>
  local file=${1-} payload event agent_id sid start_source delays delay
  payload=$(cat 2>/dev/null) || payload=
  fm_herdr_resume_in_pane || return 0
  fm_herdr_resume_usable_file "$file" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null) || return 0
  [ "$event" = SessionStart ] || return 0
  agent_id=$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null) || return 0
  [ -z "$agent_id" ] || return 0
  sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  fm_herdr_resume_usable_session "$sid" || return 0
  start_source=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null) || start_source=
  delays=${FM_HERDR_RESUME_DELAYS:-1 5}
  (
    for delay in $delays; do
      [[ "$delay" =~ ^[0-9]+$ ]] || continue
      sleep "$delay"
      fm_herdr_resume_report "$file" "$sid" "$start_source" || true
    done
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

main() {
  local cmd=${1-}
  case "$cmd" in
    hook)
      [ "$#" -eq 2 ] || exit 0
      fm_herdr_resume_hook "$2"
      exit 0
      ;;
    report)
      [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { sed -n '2,40p' "$0" >&2; exit 2; }
      fm_herdr_resume_report "$2" "$3" "${4-}"
      ;;
    -h | --help | help) sed -n '2,40p' "$0" ;;
    *) sed -n '2,40p' "$0" >&2; exit 2 ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# fm-primary-pane-lib.sh - prove that a Claude primary's own pane is safe to
# type into, for a detached helper that delivers text to its own primary.
#
# Two callers share this proof: bin/fm-supervision-handoff.sh, which rings a
# watcher doorbell, and bin/fm-helm-refresh.sh, which types /clear and then a
# doorbell. Neither may guess a pane, so the transport comes only from the
# identity the pane runtime injected into this process:
#
#   tmux   TMUX_PANE
#   herdr  HERDR_ENV=1 + HERDR_PANE_ID + HERDR_SESSION (a named session's pane,
#          including the fm-remote session remote homes run under); with
#          --default-session, a pane with no HERDR_SESSION is the default
#          session's, as bin/backends/herdr.sh's fm_backend_herdr_session reads
#          it, because a pane in Herdr's default session carries none
#
# An explicit target variable is deliberately NOT honored: the helper must
# never deliver to a pane another home or a stray environment configured.
# TMUX_PANE wins over Herdr, matching bin/fm-supervisor-target-lib.sh's
# innermost-first order.
#
# fm_primary_pane_idle_proven passes only when every fact below holds:
#   tmux   the pane's pid is an ancestor of the session pid, that session is in
#          the terminal's foreground process group, the harness pid is alive,
#          the pane reads idle for Claude, and the composer reads empty;
#   herdr  the server answers, the pane owns the session pid (ancestor-or-self
#          and foreground group, from Herdr's own process-info), the pane's
#          registered agent is claude and any session binding it carries is
#          claude's, the harness pid is alive, Herdr's native state and the
#          rendered state both read idle, and the composer reads empty.
# Busy, unknown, or pending input never passes.
#
# The caller sources bin/fm-backend.sh (with the tmux adapter, and the herdr
# adapter when that transport is used) and bin/fm-session-lock-lib.sh first.

# fm_primary_pane_transport [--default-session]: set FM_PRIMARY_PANE_TRANSPORT
# (tmux|herdr) and FM_PRIMARY_PANE_TARGET from the injected pane identity.
# Returns 1, with both empty, when this process is in no supported pane.
# shellcheck disable=SC2034 # Both are results for the sourcing caller.
fm_primary_pane_transport() {
  local session=${HERDR_SESSION:-}
  FM_PRIMARY_PANE_TRANSPORT=
  FM_PRIMARY_PANE_TARGET=
  if [ -n "${TMUX_PANE:-}" ]; then
    FM_PRIMARY_PANE_TRANSPORT=tmux
    FM_PRIMARY_PANE_TARGET=$TMUX_PANE
    return 0
  fi
  [ "${1:-}" != --default-session ] || [ -n "$session" ] || session=default
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && [ -n "$session" ]; then
    FM_PRIMARY_PANE_TRANSPORT=herdr
    FM_PRIMARY_PANE_TARGET="$session:$HERDR_PANE_ID"
    return 0
  fi
  return 1
}

# fm_primary_pane_idle_proven <transport> <target> <session-pid>
fm_primary_pane_idle_proven() {
  local transport=$1 target=$2 session=$3
  local pane_pid ancestor pgid tpgid agent_out h_session h_pane
  case "$transport" in
    tmux)
      pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || pane_pid=
      ancestor=$session
      case "$pane_pid" in ''|*[!0-9]*) ancestor= ;; esac
      while [ -n "$ancestor" ] && [ "$ancestor" != 1 ] && [ "$ancestor" != "$pane_pid" ]; do
        ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
      done
      read -r pgid tpgid < <(ps -o pgid=,tpgid= -p "$session" 2>/dev/null) || pgid=
      [ -n "$ancestor" ] && [ "$ancestor" = "$pane_pid" ] \
        && [ -n "$pgid" ] && [ "$pgid" = "$tpgid" ] && [ "$pgid" -gt 0 ] 2>/dev/null \
        && fm_harness_pid_alive "$session" \
        && [ "$(fm_pane_busy_state "$target" claude 2>/dev/null)" = idle ] \
        && [ "$(fm_backend_composer_state tmux "$target" 2>/dev/null)" = empty ]
      ;;
    herdr)
      fm_backend_herdr_parse_target "$target" || return 1
      [ "$(fm_backend_herdr_server_running_state "$FM_BACKEND_HERDR_SESSION")" = running ] || return 1
      h_session=$FM_BACKEND_HERDR_SESSION
      h_pane=$FM_BACKEND_HERDR_PANE
      # One read carries both halves of the registered-identity proof: the
      # pane's agent must be claude, and any session binding it carries must
      # be claude's own - a foreign label or binding never delivers.
      agent_out=$(fm_backend_herdr_cli "$h_session" agent get "$h_pane" 2>/dev/null) || agent_out=
      fm_backend_herdr_pane_owns_session "$h_session" "$h_pane" "$session" \
        && [ "$(printf '%s' "$agent_out" | jq -r '.result.agent.agent // empty' 2>/dev/null)" = claude ] \
        && printf '%s' "$agent_out" | jq -er '(.result.agent.agent_session.agent // "claude") == "claude"' >/dev/null 2>&1 \
        && fm_harness_pid_alive "$session" \
        && [ "$(fm_backend_herdr_busy_state "$target" 2>/dev/null)" = idle ] \
        && [ "$(fm_backend_herdr_rendered_busy_state "$target" claude 2>/dev/null)" = idle ] \
        && [ "$(fm_backend_composer_state herdr "$target" 2>/dev/null)" = empty ]
      ;;
    *) return 1 ;;
  esac
}

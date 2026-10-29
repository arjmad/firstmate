#!/usr/bin/env bash
# The systemd slice firstmate's long-lived Linux processes start in.
#
# Source this file; it defines functions only. It is the single owner of the
# decision shared by bin/backends/herdr.sh (the Herdr server) and
# bin/fm-remote-job-lib.sh (the Linux remote job worker).
#
# Why: started over SSH, those processes stay in the SSH session's scope
# (user-<uid>.slice/session-<n>.scope), so a host cannot give agent work
# limits of its own apart from everything else the account runs. Started
# through `systemd-run --user --scope --slice=firstmate.slice` they land in
# user@<uid>.service/firstmate.slice instead, and every pane, agent and job
# they later spawn inherits it. Firstmate only names the slice; its limits
# (CPU weight, memory ceiling, CPU sets) are the host's, set in a
# ~/.config/systemd/user/firstmate.slice unit or with
# `systemctl --user set-property`. A slice nobody declared has no limits.
#
# A scope runs the command in place: `systemd-run --scope` registers the scope
# and then execs it, so the pid a caller records and the process group job
# control gives it are the command's own.
#
# The slice is used only when all of these hold, and otherwise the command
# starts as before, in the caller's own scope:
#   - the platform is Linux;
#   - FM_SYSTEMD_SLICE is not `off`, the one value it takes;
#   - systemd-run and loginctl resolve;
#   - the account lingers, because without linger the user manager, and every
#     unit under it, stops when the account's last session ends, which would
#     kill a server an SSH session merely started;
#   - the user manager answers on its bus. A caller whose environment was
#     emptied (the remote entrypoint runs commands under a fixed one) has no
#     XDG_RUNTIME_DIR, so systemctl and systemd-run cannot find that bus; the
#     account's own /run/user/<uid> stands in, and the prefix carries it to
#     systemd-run. FM_USER_RUNTIME_ROOT_OVERRIDE replaces /run/user in tests.
#
# Functions:
#   fm_linux_slice_prefix [platform]
#     Sets the array FM_LINUX_SLICE_PREFIX to the command words to put before
#     a long-lived command (empty when the slice is not used) and returns 0.
#     <platform> overrides `uname -s`. Expand it as
#     ${FM_LINUX_SLICE_PREFIX[@]+"${FM_LINUX_SLICE_PREFIX[@]}"} so an empty
#     prefix stays safe under `set -u` on bash 3.2.

fm_linux_slice_prefix() { # [platform]
  local platform=${1:-} user linger runtime runtime_env=()
  # shellcheck disable=SC2034 # Sourceable API consumed by herdr.sh and fm-remote-job-lib.sh.
  FM_LINUX_SLICE_PREFIX=()
  [ -n "$platform" ] || platform=$(uname -s 2>/dev/null || true)
  case "$platform" in Linux|linux) ;; *) return 0 ;; esac
  [ "${FM_SYSTEMD_SLICE:-}" != off ] || return 0
  command -v systemd-run >/dev/null 2>&1 || return 0
  command -v loginctl >/dev/null 2>&1 || return 0
  user=$(id -un 2>/dev/null) || return 0
  linger=$(loginctl show-user "$user" --property=Linger --value 2>/dev/null) || return 0
  [ "$linger" = yes ] || return 0
  runtime=${XDG_RUNTIME_DIR:-}
  if [ -z "$runtime" ]; then
    runtime="${FM_USER_RUNTIME_ROOT_OVERRIDE:-/run/user}/$(id -u 2>/dev/null)"
    [ -d "$runtime" ] && [ -O "$runtime" ] || return 0
    runtime_env=(env "XDG_RUNTIME_DIR=$runtime")
  fi
  XDG_RUNTIME_DIR=$runtime systemctl --user show --property=Version --value >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2034 # Sourceable API consumed by herdr.sh and fm-remote-job-lib.sh.
  FM_LINUX_SLICE_PREFIX=(${runtime_env[@]+"${runtime_env[@]}"} systemd-run --user --scope --quiet --collect --slice=firstmate.slice)
}

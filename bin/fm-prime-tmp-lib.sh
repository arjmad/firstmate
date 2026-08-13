# shellcheck shell=bash
# Single owner of the task-scoped Prime Agent short TMPDIR shape. The path is
# minted once, by bin/fm-spawn.sh's `mktemp -d /tmp/fmpa.XXXXXXXX`; every other
# consumer only ever validates a recorded prime_tmp value before acting on it,
# and must do so through fm_prime_tmp_path_safe so the minted template and its
# validators cannot drift apart. The root is short and random because Unix
# socket length limits make the ordinary task-id-derived tasktmp root unusable
# for the daemon socket, and per-task uniqueness is what keeps scoped daemon
# shutdown and removal safe.
# Usage: . bin/fm-prime-tmp-lib.sh

fm_prime_tmp_path_safe() {  # <path>
  case "${1:-}" in
    /tmp/fmpa.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) return 0 ;;
  esac
  return 1
}

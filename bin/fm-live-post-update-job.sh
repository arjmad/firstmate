#!/usr/bin/env bash
# One detached run of a live checkout's post-update command, for
# bin/fm-fleet-sync.sh's post-update=detached entries. The sync starts it as a
# launchd one-shot (or, without launchd, in its own session), so the run
# outlives the sync, its process group and whatever session started it; the
# sync then follows this run's receipt. Not meant to be run by hand.
# Usage: fm-live-post-update-job.sh <record> <nonce> <head> <dir>
# It reads the command from <record>.job.cmd and the sync's exported
# environment from <record>.job.env (mode 0600), which it deletes once read,
# runs the command through bash -c from <dir> with output in <record>.job.log,
# and holds <record>.running in the format the sync's own runs write (pid and
# start time, then the process start stamp) while it runs, removing the sync's
# launch reservation <record>.job.lock once that record is written. When the command
# ends it writes the receipt <record>.job, one line
#   finished <nonce> <head> <exit> <UTC time>
# and only then removes <record>.running, so a follower that sees the run gone
# finds its receipt; the receipt keeps the last 10 runs' lines, newest last. A
# run whose nonce is not the one <record>.job.lock/nonce holds started too late
# and exits at once, running nothing. It always exits 0: the receipt carries
# the command's exit.
set -u

if [ "$#" -ne 4 ]; then
  echo "usage: fm-live-post-update-job.sh <record> <nonce> <head> <dir>" >&2
  exit 2
fi
__fm_job_record=$1 __fm_job_nonce=$2 __fm_job_head=$3 __fm_job_dir=$4

# The receipt keeps the last few runs' lines, newest last, so a sync following
# one run still finds its own line after another sync's retry has finished.
__fm_job_receipt() {
  local tmp="$__fm_job_record.job.tmp.$$"
  { tail -n 9 "$__fm_job_record.job" 2>/dev/null
    printf 'finished %s %s %s %s\n' "$__fm_job_nonce" "$__fm_job_head" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$tmp" \
    && mv -f "$tmp" "$__fm_job_record.job"
}

# A run whose sync gave up on it, or whose reservation another sync has since
# taken over, starts too late: it touches nothing and runs nothing.
__fm_job_owner=""
read -r __fm_job_owner < "$__fm_job_record.job.lock/nonce" 2>/dev/null || __fm_job_owner=""
[ "$__fm_job_owner" = "$__fm_job_nonce" ] || exit 0

if ! __fm_job_cmd=$(cat "$__fm_job_record.job.cmd" 2>/dev/null) || [ -z "$__fm_job_cmd" ]; then
  echo "fm-live-post-update-job: no command at $__fm_job_record.job.cmd" > "$__fm_job_record.job.log"
  __fm_job_receipt 126
  rm -rf "$__fm_job_record.job.lock"
  exit 0
fi
# Sourced at top level so each declare -x stays global; a read-only variable
# such as SHELLOPTS refuses its line and the rest still load.
if [ -f "$__fm_job_record.job.env" ]; then
  # shellcheck disable=SC1090 # the sync's own export -p snapshot
  . "$__fm_job_record.job.env" 2>/dev/null
  rm -f "$__fm_job_record.job.env"
fi
# Only once its inputs are read: the sync keeps another sync off them until then.
{ printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LC_ALL=C TZ=UTC0 ps -p "$$" -o lstart=; } > "$__fm_job_record.running.tmp.$$" 2>/dev/null \
  && mv -f "$__fm_job_record.running.tmp.$$" "$__fm_job_record.running"
# The sync's launch reservation ends here, once this run can be seen.
rm -rf "$__fm_job_record.job.lock"

if cd "$__fm_job_dir" 2>/dev/null; then
  bash -c "$__fm_job_cmd" </dev/null > "$__fm_job_record.job.log" 2>&1
  __fm_job_rc=$?
else
  echo "fm-live-post-update-job: cannot enter $__fm_job_dir" > "$__fm_job_record.job.log"
  __fm_job_rc=126
fi
__fm_job_receipt "$__fm_job_rc"
rm -f "$__fm_job_record.running"
exit 0

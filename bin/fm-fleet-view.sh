#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
#
# Its "Waiting Unheld" section is an action list for the heartbeat review:
# every queued row with no hold of any kind and no unresolved blocker whose
# `since` date is 7 or more days before the snapshot's own date
# (FM_FLEET_VIEW_UNHELD_DAYS), each with the action it needs - a row the
# captain owns is held for him, any other row is dispatched, dated or closed
# (fork patch, docs/fork-decisions/2026-11-20-heartbeat-lists-stale-unheld-rows.md).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json]

Render a human fleet view from fm-fleet-snapshot.sh.
Use --json to print the underlying snapshot.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $? ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?
UNHELD_DAYS=${FM_FLEET_VIEW_UNHELD_DAYS:-7}
case "$UNHELD_DAYS" in ''|*[!0-9]*) UNHELD_DAYS=7 ;; esac

printf '%s\n' "$SNAPSHOT" | jq -r --argjson unheld_days "$UNHELD_DAYS" '
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_exists($t):
    if $t.endpoint.exists == null then "unknown"
    elif $t.endpoint.exists then "present"
    else "absent" end;
  def endpoint_of($t):
    if $t.kind == "secondmate" then "\(endpoint_exists($t)) / \($t.endpoint.agent_alive)"
    else endpoint_exists($t) end;
  def artifact($t):
    if $t.pr.url != null then $t.pr.url
    elif $t.paths.report.present then $t.paths.report.path
    else "-" end;
  def path_of($t):
    if $t.paths.home.present then $t.paths.home.path
    elif $t.remote != null and $t.paths.home.path != null then $t.paths.home.path + " (remote on \($t.remote.host), not checked)"
    elif $t.paths.home.path != null then $t.paths.home.path + " (absent)"
    elif $t.paths.worktree.present then $t.paths.worktree.path
    elif $t.paths.worktree.path != null then $t.paths.worktree.path + " (absent)"
    else "-" end;
  def action_of($t):
    if $t.kind == "secondmate" then "\($t.actions.send) - \($t.actions.watch)"
    else $t.actions.watch end;
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def blocker($r):
    if ($r.blocked_by // "") == "" then "-"
    elif ($r.blocked_reason // "") == "" then $r.blocked_by
    else "\($r.blocked_by) - \($r.blocked_reason)" end;
  def waiting_unheld:
    ((.generated | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $unheld_days * 86400 | strftime("%Y-%m-%d")) as $cutoff
    | [.backlog.records[]?
       | select(.structured and .state == "queued" and .hold_kind == null and .hold_reason == null
                and .hold_until == null and ((.unresolved_blocker_ids // []) | length) == 0
                and .since != null and .since <= $cutoff)];
  def unheld_action($r):
    if $r.owned_by == "arjun" then "his own step: hold it for him (bin/fm-captain-hold.sh hold)"
    else "dispatch it, date it (hold --kind future --until), or close it" end;
  def backlog_row($r):
    "| \($r.id // "-") | \(dash($r.title // $r.raw)) | \(dash($r.repo)) | \(dash($r.kind)) | \(blocker($r)) | \(dash($r.pr_url // $r.report_path // $r.local_note)) |";

  "# Fleet View",
  "",
  "Schema: \(.schema)",
  "Home: \(.fm_home)",
  "",
  "## Under Way",
  (if (.tasks | length) == 0 then
    "No live task metadata found."
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | task_row(.))
   end),
  "",
  "## Queued",
  (if ([.backlog.records[]? | select(.state == "queued")] | length) == 0 then
    "No queued backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "queued") | backlog_row(.))
   end),
  "",
  "## Waiting Unheld",
  (waiting_unheld as $rows
   | if ($rows | length) == 0 then
       "No queued row has waited \($unheld_days) days or more without a hold."
     else
       "Each row below is queued with no hold and no blocker and was filed \($unheld_days) or more days ago; act on it this heartbeat.",
       "",
       "| ID | Title | Since | Owner | Action |",
       "| --- | --- | --- | --- | --- |",
       ($rows[] | "| \(.id) | \(dash(.title)) | \(.since) | \(dash(.owned_by)) | \(unheld_action(.)) |")
     end),
  "",
  "## Done",
  (if ([.backlog.records[]? | select(.state == "done")] | length) == 0 then
    "No done backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "done") | backlog_row(.))
   end),
  "",
  "## Secondmates",
  .secondmate_guidance.note
'

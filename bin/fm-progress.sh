#!/usr/bin/env bash
# fm-progress.sh - fast, read-only progress projection of this home's helm and
# its recorded direct reports, for a display that polls (the Claude Code band
# mod refreshes every 10 seconds).
#
# It reads only records firstmate and Claude Code already write, writes
# nothing, never asks a backend, a forge, or a pane, and never classifies
# current state: bin/fm-crew-state.sh owns that verdict, and this projection
# only reports what the records say right now. Parsing goes through each
# record's owner: status lines through bin/fm-classify-lib.sh, the busy record
# through bin/fm-busy-lib.sh.
#
# Sources:
#   state/.lock                     helm pid (bin/fm-lock.sh)
#   state/<id>.meta                 one recorded direct report each: kind,
#                                   harness, project, account, spawn_gen=s<epoch>
#   state/<id>.status               latest status event: its verb is the phase,
#                                   its [at=<epoch>] the phase start, its note
#                                   the phase text
#   state/<id>.busy-state           busy|idle|unknown and its source; a record
#                                   whose gen, form, or source does not
#                                   validate reads unknown
#   <claude-dir>/sessions/<pid>.json  Claude Code's session record: the helm's
#                                   status and statusUpdatedAt, and a Claude
#                                   worker's sessionId, found by the session
#                                   name bin/fm-spawn.sh gives every Claude
#                                   launch (claude_session_name_flag:
#                                   "<kind>: <task-id>") with a live pid
#   <claude-dir>/tasks/<sessionId>/<n>.json  that worker's own Claude Code task
#                                   list (subject, status pending|in_progress|
#                                   completed); Claude workers launch with
#                                   CLAUDE_CODE_ENABLE_TODO_TOOLS=1 so the list
#                                   exists
#
# Steps: done/total and the in-progress subject come from the worker's Claude
# task list when it has one; otherwise an optional [step=<n>/<m>] token in the
# head of the latest status line (beside [at=]) supplies done/total. The task
# list wins because it is updated continuously, while a status token moves only
# when the worker appends a phase change.
#
# Claude directories: an unpinned worker launches with its spawner's
# CLAUDE_CONFIG_DIR, which the task record does not keep, so sessions are
# matched by name and live pid across every candidate root: each pinned
# worker's meta account= root (`ordinary` is $HOME/.claude),
# FM_PROGRESS_CLAUDE_DIRS (colon-separated; a display running under another
# login names the fleet's roots here), this process's CLAUDE_CONFIG_DIR, and
# $HOME/.claude. The helm's record is looked for in the same roots, then under
# this home's config/claude-account pin.
#
# Every Claude file is read on its own, so one Claude Code is rewriting at that
# moment drops only itself: a half-written session record hides only that
# session, and a half-written task file only that task.
#
# elapsed_s counts from the earlier of spawn_gen and the first stamped status
# line, because a relaunch records a new spawn_gen.
#
# Output (--json, the default; one line):
#   {"schema":"fm-progress/v1","generated":<epoch>,"home":<path>,
#    "helm":null | {"pid":<n>,"state":"busy|idle|unknown","since":<epoch>|null,
#                   "for_s":<n>|null,"name":<str>|null},
#    "workers":[{"id","kind","harness","repo","phase","phase_at","in_phase_s",
#                "text","elapsed_s","busy","busy_source",
#                "steps":null | {"done","total","current","source":"task-list|status-token"}}]}
# --line renders the same projection as short terminal lines.
#
# Exit 0 on a successful read, 1 when jq is missing, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
usage: fm-progress.sh [--json|--line]

Print a read-only progress projection of this home's helm and its recorded
direct reports: phase, time in phase, busy state, and step n/m from a Claude
worker's task list or a [step=n/m] status token. FM_HOME selects the home.
See the header comment for sources and the output contract.
EOF
}

MODE=--json
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json|--line) MODE=$1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-progress: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

NOW=${EPOCHSECONDS:-$(date +%s)}
TEXT_MAX=200

# Tabs and newlines would split the row records handed to jq below.
one_field() {  # <value> <out-var>
  local v=${1//$'\t'/ }
  printf -v "$2" '%s' "${v//$'\n'/ }"
}

# Read every key this projection needs from one meta in a single pass.
read_meta() {  # <meta-file>
  local line
  m_kind='' m_harness='' m_project='' m_account='' m_spawn=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) m_kind=${line#kind=} ;;
      harness=*) m_harness=${line#harness=} ;;
      project=*) m_project=${line#project=} ;;
      account=*) m_account=${line#account=} ;;
      spawn_gen=s*) m_spawn=${line#spawn_gen=s}; m_spawn=${m_spawn%%.*} ;;
    esac
  done < "$1" 2>/dev/null
  case "$m_spawn" in ''|*[!0-9]*) m_spawn='' ;; esac
}

# The busy record through its owner: a valid, gen-matching record from a source
# trusted for this harness gives its state; anything else is unknown.
busy_of() {  # <id> <harness> -> sets b_state b_source
  local out rest
  b_state=unknown
  if out=$(fm_busy_record_read "$STATE" "$1"); then
    rest=${out#* }
    b_source=${rest%% *}
    if fm_busy_source_trusted "$2" "$b_source"; then
      b_state=${out%% *}
    else
      b_source=source-mismatch
    fi
  else
    b_source=$out
  fi
}

add_dir() {  # <dir> - append to CLAUDE_DIRS once
  local d
  [ -n "$1" ] || return 0
  for d in "${CLAUDE_DIRS[@]+"${CLAUDE_DIRS[@]}"}"; do
    [ "$d" = "$1" ] && return 0
  done
  CLAUDE_DIRS+=("$1")
}

# Append one file to FILE_ARGS as a "<path> <content>" pair for jq's
# --args, read with builtins so a file removed mid-scan is skipped quietly and
# no file costs a process.
add_file() {  # <path>
  local text=''
  [ -f "$1" ] || return 0
  IFS= read -r -d '' text 2>/dev/null < "$1" || [ -n "$text" ] || return 0
  FILE_ARGS+=("$1" "$text")
}

# The first stamped status line's epoch, or nothing.
first_stamp() {  # <status-file>
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    case "$line" in *[![:space:]]*) status_line_at_epoch "$line" || :; return 0 ;; esac
  done 2>/dev/null < "$1"
}

ROWS=''
CLAUDE_DIRS=()
CLAUDE_WORKERS=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  read_meta "$meta"
  last=$(last_status_line "$STATE/$id.status")
  if [ -n "$last" ]; then
    status_line_verb "$last" phase
    phase_at=$(status_line_at_epoch "$last") || phase_at=''
    text=$(status_line_note "$last")
    step=''
    case "${last%%:*}" in
      *\[step=*\]*) step=${last%%:*}; step=${step#*\[step=}; step=${step%%\]*} ;;
    esac
    case "$step" in
      [0-9]*/[0-9]*) case "${step%/*}${step#*/}" in *[!0-9]*) step='' ;; esac ;;
      *) step='' ;;
    esac
  else
    phase=starting phase_at=$m_spawn text='' step=''
  fi
  started=$(first_stamp "$STATE/$id.status")
  if [ -z "$m_spawn" ] || { [ -n "$started" ] && [ "$started" -lt "$m_spawn" ]; }; then
    m_spawn=${started:-$m_spawn}
  fi
  one_field "${text:0:$TEXT_MAX}" text
  one_field "$phase" phase
  busy_of "$id" "$m_harness"
  case "$m_harness" in
    claude*)
      case "$m_account" in
        ordinary) add_dir "$HOME/.claude" ;;
        /*) add_dir "$m_account" ;;
      esac
      CLAUDE_WORKERS+=("$m_kind: $id"$'\t'"$id")
      ;;
  esac
  ROWS+="$id"$'\t'"$m_kind"$'\t'"$m_harness"$'\t'"${m_project##*/}"$'\t'"$phase"$'\t'"$phase_at"$'\t'"$text"$'\t'"$m_spawn"$'\t'"$b_state"$'\t'"$b_source"$'\t'"$step"$'\n'
done
IFS=: read -r -a extra_dirs <<< "${FM_PROGRESS_CLAUDE_DIRS:-}"
for d in "${extra_dirs[@]+"${extra_dirs[@]}"}" "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
  add_dir "$d"
done

# The helm: the live holder of this home's session lock.
HELM_PID=''
if [ -f "$STATE/.lock" ]; then
  IFS= read -r HELM_PID < "$STATE/.lock" 2>/dev/null || :
  case "$HELM_PID" in ''|*[!0-9]*) HELM_PID='' ;; esac
  [ -z "$HELM_PID" ] || kill -0 "$HELM_PID" 2>/dev/null || HELM_PID=''
fi
HELM_FILE=''
if [ -n "$HELM_PID" ]; then
  for d in "${CLAUDE_DIRS[@]}"; do
    [ -f "$d/sessions/$HELM_PID.json" ] && { HELM_FILE=$d/sessions/$HELM_PID.json; break; }
  done
  if [ -z "$HELM_FILE" ] && [ -f "$FM_HOME/config/claude-account" ]; then
    # shellcheck source=bin/fm-worker-account-lib.sh
    . "$SCRIPT_DIR/fm-worker-account-lib.sh"
    pin=$(fm_worker_account_read claude "$FM_HOME/config/claude-account" 2>/dev/null) || pin=''
    pin=${pin%%$'\t'*}
    case "$pin" in /*) [ -f "$pin/sessions/$HELM_PID.json" ] && HELM_FILE=$pin/sessions/$HELM_PID.json ;; esac
  fi
fi

# A Claude worker's session: the newest live interactive session carrying its
# launch name, in any candidate root. One jq reads every session record.
TASK_DIRS=''
if [ "${#CLAUDE_WORKERS[@]}" -gt 0 ]; then
  FILE_ARGS=()
  for d in "${CLAUDE_DIRS[@]}"; do
    for f in "$d"/sessions/*.json; do
      add_file "$f"
    done
  done
  sessions=''
  if [ "${#FILE_ARGS[@]}" -gt 0 ]; then
    sessions=$(jq -r -n '
      $ARGS.positional as $a
      | range(0; $a | length; 2) as $i
      | ($a[$i + 1] | try fromjson catch null)
      | select(type == "object" and .kind == "interactive" and (.name | type) == "string"
             and (.sessionId | type) == "string" and (.pid | type) == "number")
      | [.name, .sessionId, (.pid | tostring), ((.startedAt // 0) | tostring),
         ($a[$i] | sub("/sessions/[^/]*$"; ""))] | @tsv' \
      --args "${FILE_ARGS[@]}" 2>/dev/null) || :
  fi
  for w in "${CLAUDE_WORKERS[@]}"; do
    name=${w%%$'\t'*}
    wid=${w#*$'\t'}
    best='' best_start=-1
    while IFS=$'\t' read -r s_name s_sid s_pid s_start s_dir; do
      [ "$s_name" = "$name" ] || continue
      case "$s_sid" in ''|*/*|.*) continue ;; esac
      case "$s_start" in ''|*[!0-9]*) s_start=0 ;; esac
      kill -0 "$s_pid" 2>/dev/null || continue
      [ "$s_start" -gt "$best_start" ] || continue
      best="$s_dir/tasks/$s_sid" best_start=$s_start
    done <<EOF
$sessions
EOF
    [ -n "$best" ] && [ -d "$best" ] && TASK_DIRS+="$wid"$'\t'"$best"$'\n'
  done
fi

FILE_ARGS=()
[ -z "$HELM_FILE" ] || add_file "$HELM_FILE"
while IFS=$'\t' read -r wid tdir; do
  [ -n "$wid" ] || continue
  for f in "$tdir"/*.json; do
    add_file "$f"
  done
done <<EOF
$TASK_DIRS
EOF

# One jq projects the rows, the helm's session record, and every task file.
JSON=$(
  jq -c -n --argjson now "$NOW" --arg home "$FM_HOME" --arg rows "$ROWS" \
    --arg taskdirs "$TASK_DIRS" --arg helm_pid "$HELM_PID" --arg helm_file "$HELM_FILE" '
    def num: if . == "" or . == null then null else tonumber end;
    $ARGS.positional as $a
    | [range(0; $a | length; 2) as $i | {f: $a[$i], v: ($a[$i + 1] | try fromjson catch null)}] as $in
    | ([$in[] | select(.f != $helm_file and (.v | type) == "object")]
       | group_by(.f | sub("/[^/]*$"; ""))
       | map({key: (.[0].f | sub("/[^/]*$"; "")),
              value: [.[].v | select(.status != "deleted")]})
       | from_entries) as $lists
    | ($taskdirs | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]})
       | from_entries) as $wdirs
    | ([$in[] | select(.f == $helm_file and (.v | type) == "object") | .v] | .[0]) as $hs
    | {schema: "fm-progress/v1", generated: $now, home: $home,
       helm: (if $helm_pid == "" then null
              else ($hs.statusUpdatedAt // $hs.updatedAt // null) as $ms
                | (if $ms == null then null else ($ms / 1000 | floor) end) as $since
                | {pid: ($helm_pid | tonumber),
                   state: (if $hs == null then "unknown" else ($hs.status // "unknown") end),
                   since: $since,
                   for_s: (if $since == null then null else $now - $since end),
                   name: ($hs.name // null)} end),
       workers: [$rows | split("\n")[] | select(. != "") | split("\t")
         | {id: .[0], kind: .[1], harness: .[2], repo: .[3], phase: .[4],
            phase_at: (.[5] | num), text: .[6], spawned: (.[7] | num),
            busy: .[8], busy_source: .[9], step: .[10]}
         | . as $w
         | ($lists[$wdirs[$w.id] // ""] // []) as $tasks
         | {id, kind, harness, repo, phase, phase_at,
            in_phase_s: (if .phase_at == null then null else $now - .phase_at end),
            text,
            elapsed_s: (if .spawned == null then null else $now - .spawned end),
            busy, busy_source,
            steps: (if ($tasks | length) > 0 then
                      {done: ([$tasks[] | select(.status == "completed")] | length),
                       total: ($tasks | length),
                       current: ([$tasks[] | select(.status == "in_progress") | .subject // ""][0] // ""),
                       source: "task-list"}
                    elif $w.step != "" then
                      ($w.step | split("/") | map(tonumber)) as $s
                      | if $s[1] > 0 then {done: $s[0], total: $s[1], current: "", source: "status-token"}
                        else null end
                    else null end)}]}' --args "${FILE_ARGS[@]+"${FILE_ARGS[@]}"}"
)

if [ "$MODE" = --json ]; then
  printf '%s\n' "$JSON"
  exit 0
fi

printf '%s\n' "$JSON" | jq -r '
  def dur($s): if $s == null then "?"
               elif $s >= 3600 then "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m"
               elif $s >= 60 then "\($s / 60 | floor)m" else "\($s)s" end;
  def bar($d; $t): ([($d * 10 / $t | floor), 10] | min) as $f
    | ("█" * $f) + ("░" * (10 - $f)) + " \($d)/\($t)";
  def glyph: {working: "▶", "gate-wait": "⏳", paused: "⏸", "needs-decision": "❓",
              blocked: "⛔", ready: "✅", done: "✅", failed: "✖"}[.] // "·";
  (if .helm then " · helm \(.helm.state) \(dur(.helm.for_s))" else "" end) as $helm
  | if (.workers | length) == 0 then "fleet: no workers" + $helm
    else "fleet: \(.workers | length) workers · \([.workers[] | select(.busy == "busy")] | length) busy" + $helm,
      (.workers[] | "\(.phase | glyph) \(.id) \(dur(.elapsed_s)) · \(.phase) \(dur(.in_phase_s))"
        + (if .steps then " · " + bar(.steps.done; .steps.total) else "" end)
        + " · " + ((if (.steps.current // "") != "" then .steps.current else .text end)[0:60]))
    end'

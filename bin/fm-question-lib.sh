#!/usr/bin/env bash
# fm-question-lib.sh - the shared records behind a captain question that holds
# a Claude primary's turn open (AskUserQuestion), sourced by its PreToolUse
# guard (bin/fm-question-pretool-check.sh), its keeper
# (bin/fm-question-keeper.sh), and the supervision host
# (bin/fm-supervision-host.sh). This file is the one owner of which tool names
# block, the presence window, and the three records below.
#
# PRESENCE. The captain is present when the newest thing he did in this main
# session is recent: his newest real prompt in the dialog mirror
# (bin/fm-host-mirror.sh captain-epoch, which already drops rewakes and
# operational input) or his newest answer to a question, which is a tool
# result and so never a prompt. FM_QUESTION_PRESENT_SECONDS (default 600)
# bounds "recent".
#
# RECORDS (all under state/):
#   .question-open      "<keeper pid>\t<identity>\t<tool use id>\t<epoch>":
#                       a keeper is watching an open question. While it names
#                       a live keeper under its identity, the supervision host
#                       holds every close it would hand to main instead of
#                       ending its park (fm_question_hold_open).
#   .question-held      the closes held that way, oldest first, appended under
#                       .question-held.lock; the keeper takes and delivers them
#                       when the question closes.
#   .question-answered  "<epoch>\t<main-session key>": when the captain last
#                       closed a question by answering or cancelling it.
#
# Callers source bin/fm-wake-lib.sh and bin/fm-supervision-engine-lib.sh first.

# Exact normalized (lowercase, alphanumeric) names of tools that hold the turn
# open until the captain answers. Extend only with a tool verified to block.
FM_QUESTION_BLOCKING_TOOLS='askuserquestion'

# fm_question_tool_blocks <tool-name>: 0 when the tool holds the turn open.
fm_question_tool_blocks() {
  local normalized name
  normalized=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9')
  for name in $FM_QUESTION_BLOCKING_TOOLS; do
    [ "$normalized" != "$name" ] || return 0
  done
  return 1
}

fm_question_present_window() {
  case "${FM_QUESTION_PRESENT_SECONDS:-}" in
    ''|0*|*[!0-9]*) printf '600\n' ;;
    *) printf '%s\n' "$FM_QUESTION_PRESENT_SECONDS" ;;
  esac
}

# fm_question_captain_present <state-dir> <bin-dir>: 0 when the captain's
# newest prompt or answer in this main session is inside the presence window.
# Sets FM_QUESTION_CAPTAIN_AGE to its age in seconds, or empty when none is
# known.
FM_QUESTION_CAPTAIN_AGE=
fm_question_captain_present() {
  local state=$1 bin=$2 now newest=0 epoch key stamp_epoch stamp_key
  FM_QUESTION_CAPTAIN_AGE=
  now=$(date +%s)
  epoch=$(FM_STATE_OVERRIDE="$state" "$bin/fm-host-mirror.sh" captain-epoch 2>/dev/null) || epoch=
  case "$epoch" in ''|*[!0-9]*) ;; *) newest=$epoch ;; esac
  if [ -f "$state/.question-answered" ] && key=$(fm_supervision_host_main_key "$state"); then
    IFS="$(printf '\t')" read -r stamp_epoch stamp_key < "$state/.question-answered" || true
    case "${stamp_epoch:-}" in
      ''|*[!0-9]*) ;;
      *) [ "${stamp_key:-}" != "$key" ] || [ "$stamp_epoch" -le "$newest" ] || newest=$stamp_epoch ;;
    esac
  fi
  [ "$newest" -gt 0 ] || return 1
  FM_QUESTION_CAPTAIN_AGE=$((now - newest))
  [ "$FM_QUESTION_CAPTAIN_AGE" -ge 0 ] || FM_QUESTION_CAPTAIN_AGE=0
  [ "$FM_QUESTION_CAPTAIN_AGE" -le "$(fm_question_present_window)" ]
}

# fm_question_keepable <state-dir> <config-dir> <transcript-path>: 0 when a
# keeper can keep supervision running while a question waits: the home runs
# the attended supervision host on this Claude primary, and the session
# transcript, where the question's tool result marks its close, is readable.
# Sets FM_QUESTION_UNKEEPABLE to why not.
FM_QUESTION_UNKEEPABLE=
fm_question_keepable() {
  FM_QUESTION_UNKEEPABLE=
  if ! fm_supervision_host_attended_ready "$2" claude; then
    FM_QUESTION_UNKEEPABLE=$FM_SUPERVISION_HOST_UNREADY
  elif [ -z "$3" ] || [ ! -f "$3" ] || [ ! -r "$3" ]; then
    FM_QUESTION_UNKEEPABLE="the session transcript cannot be read"
  fi
  [ -z "$FM_QUESTION_UNKEEPABLE" ]
}

# fm_question_closed <transcript-path> <tool-use-id>: 0 once the transcript
# records the tool result for that question, which Claude writes when the
# captain answers and when he cancels.
fm_question_closed() {
  [ -n "$2" ] && [ -r "$1" ] || return 1
  grep -F "\"tool_use_id\":\"$2\"" "$1" 2>/dev/null \
    | jq -e --arg id "$2" 'select(.type == "user") | .message.content
        | select(type == "array") | .[] | select(type == "object" and .type == "tool_result" and .tool_use_id == $id)' \
      >/dev/null 2>&1
}

fm_question_open_write() {  # <state-dir> <tool-use-id>
  local tmp identity
  identity=$(_fm_engine_identity "$$") || return 1
  tmp=$(mktemp "$1/.question-open.tmp.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\t%s\t%s\t%s\n' "$$" "$identity" "$2" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$1/.question-open" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Remove the open record only while it is still this process's.
fm_question_open_clear() {  # <state-dir>
  local pid=''
  [ -f "$1/.question-open" ] || return 0
  IFS="$(printf '\t')" read -r pid _ < "$1/.question-open" || true
  [ "$pid" != "$$" ] || rm -f "$1/.question-open" 2>/dev/null || true
}

# fm_question_hold_open <state-dir>: 0 while the open record names a live
# keeper under its recorded identity.
fm_question_hold_open() {
  local pid='' identity='' id='' epoch=''
  [ -f "$1/.question-open" ] && [ ! -L "$1/.question-open" ] || return 1
  IFS="$(printf '\t')" read -r pid identity id epoch < "$1/.question-open" || true
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$identity" ] && fm_pid_alive "$pid" && [ "$(_fm_engine_identity "$pid")" = "$identity" ]
}

fm_question_hold_append() {  # <state-dir> <text>
  local rc=0
  [ -n "$2" ] || return 0
  fm_lock_acquire_wait "$1/.question-held.lock" || return 1
  printf '%s\n' "$2" >> "$1/.question-held" 2>/dev/null || rc=1
  fm_lock_release "$1/.question-held.lock"
  return "$rc"
}

# Print every held close and clear the record.
fm_question_hold_take() {  # <state-dir>
  [ -f "$1/.question-held" ] || return 0
  fm_lock_acquire_wait "$1/.question-held.lock" || return 1
  cat "$1/.question-held" 2>/dev/null
  rm -f "$1/.question-held" 2>/dev/null
  fm_lock_release "$1/.question-held.lock"
}

fm_question_answered_stamp() {  # <state-dir>
  local key tmp
  key=$(fm_supervision_host_main_key "$1") || return 1
  tmp=$(mktemp "$1/.question-answered.tmp.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\t%s\n' "$(date +%s)" "$key" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1/.question-answered" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

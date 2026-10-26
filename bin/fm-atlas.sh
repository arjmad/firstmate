#!/usr/bin/env bash
# fm-atlas.sh - hand an Atlas build's top 7 ideas to bearings, and keep the
# record its keep test reads.
#
# Usage:
#   fm-atlas.sh file <atlas.json> [--board <http(s) url>]
#   fm-atlas.sh latest
#   fm-atlas.sh pick <task-id> <do-it|drop>
#   fm-atlas.sh measure <task-id> --gain yes|no --result <text>
#   fm-atlas.sh keep-test
#
# Atlas is the on-demand fleet map the store's /atlas skill builds
# (~/code/skills/skills/atlas). Its build writes atlas.json: schema atlas.v1,
# built_at, and seven ideas, each {id, slug, box, tag, text, estimate,
# evidence, repo, brief}. Atlas has no answer handling of its own: every idea
# becomes an ordinary captain hold, so bearings shows it as a decision card and
# its answer goes through the one keyed-answer intake like any other call.
#
# AN IDEA IS ITS SLUG, AS FIRST OFFERED. The task id is atlas-<slug>, and the
# first build that lists a slug owns it: the card keeps that build's wording,
# a pick dispatches that build's brief and repo, and the keep test credits that
# build. A later build listing the same slug while its card is open changes
# nothing, and an answered idea is never asked again.
#
# file       Validate atlas.json, then hold each idea not yet offered for the
#            captain through bin/fm-captain-hold.sh, titled with the idea and
#            repo'd to its repo, kind reversible with no default (an idea never
#            picks itself), the reason carrying its rank, estimate, evidence and
#            the brief a "do it" starts. One line per idea:
#              held: atlas-<slug>      newly on the board
#              open: atlas-<slug>      still on the board from an earlier build
#              skipped: atlas-<slug> (answered in an earlier build)
#              failed: atlas-<slug> (<why>)
#            Then the build is recorded in the order builds were first filed;
#            refiling one updates it in place. --board records the board link
#            (http or https, as bearings links it); without it a refiled build
#            keeps the link it had. Exit 1 when any hold failed, 2 for a refused
#            argument or file.
# latest     Print the latest build as JSON {built_at, board, file}, or
#            nothing (exit 1) before the first build. board is null when no
#            link was recorded.
# pick       Record the captain's pick on an Atlas card; the bearings board-wake
#            handler runs it after the intake recorded the answer. For do-it it
#            prints `dispatch: <repo><TAB><brief>`, the fleet task to file
#            through the normal lifecycle; drop prints nothing more. A task id
#            that is no Atlas idea is refused (exit 2).
# measure    Record the later measured result of a do-it idea: --gain says
#            whether it showed a measured gain, --result one line of evidence.
# keep-test  Print the keep test as JSON: the first two builds, the ideas
#            picked from them with their results, how many of their ideas are
#            still unanswered, and the verdict - met (at least two picked, one
#            with a measured gain), not-met (every idea of the first two builds
#            answered with fewer than two picked, or every pick measured
#            without a gain), or open. It is a read; it pings nobody.
#
# The record is state/atlas/record.json, written under state/atlas/record.lock.
# FM_ATLAS_NOW (UTC ISO-8601) fixes the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/atlas/record.json"
LOCK="$STATE/atlas/record.lock"
NOW=${FM_ATLAS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'fm-atlas: %s\n' "$*" >&2
  exit 2
}

record() {
  if [ -f "$RECORD" ]; then
    cat "$RECORD"
  else
    printf '{"schema":"fm-atlas.v1","latest":null,"builds":[],"picks":{}}\n'
  fi
}

# One writer at a time: a board-wake pick can land while a build is filed.
# A lock older than a minute is a dead writer's and is taken over.
lock_record() {
  local tries=0
  mkdir -p "${LOCK%/*}"
  until mkdir "$LOCK" 2>/dev/null; do
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || { echo "fm-atlas: $LOCK is held" >&2; exit 1; }
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

write_record() {  # JSON on stdin; call under lock_record
  local tmp
  tmp=$(mktemp "$RECORD.XXXXXX") || exit 1
  if jq . > "$tmp"; then
    mv "$tmp" "$RECORD"
  else
    rm -f "$tmp"
    exit 1
  fi
}

# The idea a task id names, from the first build that listed its slug.
first_offer() {  # <slug>
  record | jq -c --arg s "$1" \
    'first(.builds[] | .built_at as $at | .ideas[] | select(.slug == $s) | . + {built_at: $at}) // empty'
}

valid_atlas() {  # <atlas.json>
  jq -e '
    def text: type == "string" and test("[^[:space:]]") and (test("[\n\r]") | not);
    .schema == "atlas.v1"
    and (.built_at | text)
    and (.ideas | type == "array" and length == 7)
    and ([.ideas | to_entries[] | .key as $n | .value
      | (.id == "A\($n + 1)")
        and (.slug | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$"))
        and all(.box, .tag, .text, .estimate, .evidence, .repo, .brief; text)] | all)
    and ([.ideas[].slug] | length == (unique | length))
  ' "$1" >/dev/null 2>&1
}

cmd_file() {
  local file="" board="" offered slug title repo reason out status=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) shift; board=${1:-} ;;
      -*) refuse "unknown option $1" ;;
      *) [ -z "$file" ] || refuse "one atlas.json only"; file=$1 ;;
    esac
    shift
  done
  [ -n "$file" ] || refuse "file needs <atlas.json>"
  [ -f "$file" ] || refuse "no such file: $file"
  case "$board" in ''|http://?*|https://?*) ;; *) refuse "--board must be an http or https URL" ;; esac
  case "$board" in *[[:space:]]*) refuse "--board must be an http or https URL" ;; esac
  valid_atlas "$file" || refuse "$file is not an atlas.v1 build with seven ranked ideas"
  lock_record
  # Slugs some earlier build already offered: their cards are open or answered.
  offered=$(record | jq -r '[.builds[].ideas[].slug] | unique[]')
  while IFS=$'\t' read -r slug title repo reason; do
    if grep -Fxq -- "$slug" <<<"$offered"; then
      if [ -z "$(record | jq -r --arg s "$slug" '.picks[$s].pick // empty')" ] \
        && "$SCRIPT_DIR/fm-captain-hold.sh" open "atlas-$slug" >/dev/null 2>&1; then
        printf 'open: atlas-%s\n' "$slug"
      else
        printf 'skipped: atlas-%s (answered in an earlier build)\n' "$slug"
      fi
      continue
    fi
    if out=$("$SCRIPT_DIR/fm-captain-hold.sh" hold "atlas-$slug" --title "$title" --repo "$repo" \
      --kind reversible --reason "$reason" 2>&1); then
      printf 'held: atlas-%s\n' "$slug"
    else
      case "$out" in
        *"already closed"*) printf 'skipped: atlas-%s (answered in an earlier build)\n' "$slug" ;;
        *) printf 'failed: atlas-%s (%s)\n' "$slug" "$(printf '%s' "$out" | tr '\n' ' ')"; status=1 ;;
      esac
    fi
  done < <(jq -r '.ideas[] | [.slug, .text, .repo,
    "Atlas \(.id), \(.estimate): \(.evidence) Do it: \(.brief)"] | @tsv' "$file")
  record | jq --slurpfile b "$file" --arg board "$board" \
    --arg file "$(cd "$(dirname "$file")" && pwd)/${file##*/}" '
    ($b[0]) as $build
    | ([.builds[] | select(.built_at == $build.built_at) | .board][0]) as $had
    | (if $board == "" then $had else $board end) as $link
    | {built_at: $build.built_at, board: $link,
       ideas: [$build.ideas[] | {id, slug, text, estimate, repo, brief}]} as $entry
    | .builds = (if any(.builds[]; .built_at == $build.built_at)
        then [.builds[] | if .built_at == $build.built_at then $entry else . end]
        else .builds + [$entry] end)
    | .latest = {built_at: $build.built_at, board: $link, file: $file}
  ' | write_record
  return "$status"
}

cmd_latest() {
  [ $# -eq 0 ] || refuse "latest takes no arguments"
  record | jq -e '.latest // empty' 2>/dev/null || exit 1
}

cmd_pick() {
  [ $# -eq 2 ] || refuse "pick needs <task-id> <do-it|drop>"
  local id=$1 pick=$2 slug idea
  case "$pick" in do-it|drop) ;; *) refuse "unknown pick $pick" ;; esac
  case "$id" in atlas-*) slug=${id#atlas-} ;; *) refuse "$id is not an Atlas idea" ;; esac
  lock_record
  idea=$(first_offer "$slug")
  [ -n "$idea" ] || refuse "$id is not an Atlas idea"
  record | jq --arg s "$slug" --arg pick "$pick" --arg at "$NOW" --argjson idea "$idea" '
    .picks[$s] = (.picks[$s] // {}) + {pick: $pick, at: $at, built_at: $idea.built_at, text: $idea.text}
  ' | write_record
  printf 'picked: %s %s\n' "$id" "$pick"
  if [ "$pick" = do-it ]; then
    jq -r '"dispatch: \(.repo)\t\(.brief)"' <<<"$idea"
  fi
}

cmd_measure() {
  local slug="" gain="" result=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --gain) shift; gain=${1:-} ;;
      --result) shift; result=${1:-} ;;
      -*) refuse "unknown option $1" ;;
      *) [ -z "$slug" ] || refuse "one task id only"; slug=${1#atlas-} ;;
    esac
    shift
  done
  [ -n "$slug" ] || refuse "measure needs <task-id>"
  case "$gain" in yes|no) ;; *) refuse "--gain must be yes or no" ;; esac
  case "$result" in ''|*$'\n'*) refuse "--result must be one line" ;; esac
  lock_record
  record | jq -e --arg s "$slug" '.picks[$s].pick == "do-it"' >/dev/null \
    || refuse "atlas-$slug is not a picked Atlas idea"
  record | jq --arg s "$slug" --arg gain "$gain" --arg result "$result" --arg at "$NOW" '
    .picks[$s] += {gain: ($gain == "yes"), result: $result, measured_at: $at}
  ' | write_record
  printf 'measured: atlas-%s gain=%s\n' "$slug" "$gain"
}

cmd_keep_test() {
  [ $# -eq 0 ] || refuse "keep-test takes no arguments"
  record | jq '
    .picks as $picks
    | (.builds[:2] | map(.built_at)) as $first
    | ([.builds[:2][].ideas[].slug] | unique) as $slugs
    | [$slugs[] | select($picks[.] == null)] as $open
    | [$picks | to_entries[] | select(.value.pick == "do-it" and (.value.built_at as $b | $first | index($b) != null))
        | {slug: .key, text: .value.text, built_at: .value.built_at,
           result: (.value.result // null), gain: (.value.gain // null)}] as $picked
    | ([$picked[] | select(.gain == true)] | length) as $gains
    | {builds: $first, picked: $picked, unanswered: ($open | length), measured_gains: $gains,
       verdict: (if ($picked | length) >= 2 and $gains >= 1 then "met"
         elif ($first | length) >= 2 and ($open | length) == 0 and ($picked | length) < 2 then "not-met"
         elif ($picked | length) >= 2 and all($picked[]; .gain == false) then "not-met"
         else "open" end)}
  '
}

command -v jq >/dev/null 2>&1 || { echo "fm-atlas: jq is required" >&2; exit 1; }
case "${1:-}" in
  file) shift; cmd_file "$@" ;;
  latest) shift; cmd_latest "$@" ;;
  pick) shift; cmd_pick "$@" ;;
  measure) shift; cmd_measure "$@" ;;
  keep-test) shift; cmd_keep_test "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

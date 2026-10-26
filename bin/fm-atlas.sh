#!/usr/bin/env bash
# fm-atlas.sh - hand an Atlas build's top 7 ideas to bearings, and keep the
# record its keep test reads.
#
# Usage:
#   fm-atlas.sh file <atlas.json> [--board <url>]
#   fm-atlas.sh latest
#   fm-atlas.sh pick <task-id> <do-it|drop>
#   fm-atlas.sh measure <slug> --gain yes|no --result <text>
#   fm-atlas.sh keep-test
#
# Atlas is the on-demand fleet map the store's /atlas skill builds
# (~/code/skills/skills/atlas). Its build writes atlas.json: schema atlas.v1,
# built_at, and seven ideas, each {id, slug, box, tag, text, estimate,
# evidence, repo, brief}. Atlas has no answer handling of its own: every idea
# becomes an ordinary captain hold, so bearings shows it as a decision card and
# its answer goes through the one keyed-answer intake like any other call.
#
# file       Validate atlas.json, then hold each idea for the captain through
#            bin/fm-captain-hold.sh as task atlas-<slug>, titled with the idea
#            and repo'd to its repo, kind reversible with no default (an idea
#            never picks itself), the reason carrying its rank, estimate,
#            evidence and the brief a "do it" starts. One line per idea:
#              held: atlas-<slug>      newly on the board, or still open there
#              skipped: atlas-<slug> (<why>)   e.g. already answered
#            An idea answered in an earlier build stays answered: the slug is
#            the idea's identity, so the same idea is never asked twice. Then
#            the build is recorded, with --board as the latest Atlas board link.
#            Exit 1 when any hold failed, 2 for a refused argument or file.
# latest     Print the latest build as JSON {built_at, board, file}, or
#            nothing (exit 1) before the first build.
# pick       Record the captain's pick on an Atlas card; the bearings board-wake
#            handler runs it after the intake recorded the answer. For do-it it
#            prints `dispatch: <repo><TAB><brief>`, the fleet task to file
#            through the normal lifecycle; drop prints nothing more. A task id
#            that is no Atlas idea is refused (exit 2).
# measure    Record the later measured result of a picked idea: --gain says
#            whether it showed a measured gain, --result one line of evidence.
# keep-test  Print the keep test as JSON: the first two builds, the ideas
#            picked from them with their results, and the verdict - met (at
#            least two picked, one with a measured gain), not-met (two builds
#            with fewer than two picked, or every pick measured without a
#            gain), or open. It is a read; it pings nobody.
#
# The record is state/atlas/record.json. FM_ATLAS_NOW (UTC ISO-8601) fixes the
# clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/atlas/record.json"
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

write_record() {  # JSON on stdin
  local tmp
  mkdir -p "${RECORD%/*}"
  tmp=$(mktemp "$RECORD.XXXXXX") || exit 1
  if jq . > "$tmp"; then
    mv "$tmp" "$RECORD"
  else
    rm -f "$tmp"
    exit 1
  fi
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
  local file="" board="" ideas idea id slug title repo reason out status=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) shift; board=${1:-}; [ -n "$board" ] || refuse "--board needs a URL" ;;
      -*) refuse "unknown option $1" ;;
      *) [ -z "$file" ] || refuse "one atlas.json only"; file=$1 ;;
    esac
    shift
  done
  [ -n "$file" ] || refuse "file needs <atlas.json>"
  [ -f "$file" ] || refuse "no such file: $file"
  valid_atlas "$file" || refuse "$file is not an atlas.v1 build with seven ranked ideas"
  ideas=$(jq -c '.ideas[]' "$file")
  while IFS= read -r idea; do
    slug=$(jq -r .slug <<<"$idea")
    id="atlas-$slug"
    title=$(jq -r .text <<<"$idea")
    repo=$(jq -r .repo <<<"$idea")
    reason=$(jq -r '"Atlas \(.id), \(.estimate): \(.evidence) Do it: \(.brief)"' <<<"$idea")
    if [ "$(record | jq -r --arg s "$slug" '.picks[$s].pick // empty')" != "" ]; then
      printf 'skipped: %s (answered in an earlier build)\n' "$id"
      continue
    fi
    if out=$("$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --title "$title" --repo "$repo" \
      --kind reversible --reason "$reason" 2>&1); then
      printf 'held: %s\n' "$id"
    else
      case "$out" in
        *"already closed"*) printf 'skipped: %s (answered in an earlier build)\n' "$id" ;;
        *"different title"*) printf 'skipped: %s (still open under its first wording)\n' "$id" ;;
        *) printf 'failed: %s (%s)\n' "$id" "$(printf '%s' "$out" | tr '\n' ' ')"; status=1 ;;
      esac
    fi
  done <<<"$ideas"
  record | jq --slurpfile b "$file" --arg board "$board" --arg file "$(cd "$(dirname "$file")" && pwd)/${file##*/}" '
    ($b[0]) as $build
    | .latest = {built_at: $build.built_at, board: (if $board == "" then null else $board end), file: $file}
    | .builds = ([.builds[] | select(.built_at != $build.built_at)]
        + [{built_at: $build.built_at, board: .latest.board,
            ideas: [$build.ideas[] | {id, slug, text, estimate, repo, brief}]}])
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
  idea=$(record | jq -c --arg s "$slug" '[.builds[] | .built_at as $at | .ideas[] | select(.slug == $s) | . + {built_at: $at}] | last // empty')
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
      *) [ -z "$slug" ] || refuse "one slug only"; slug=$1 ;;
    esac
    shift
  done
  [ -n "$slug" ] || refuse "measure needs <slug>"
  case "$gain" in yes|no) ;; *) refuse "--gain must be yes or no" ;; esac
  case "$result" in ''|*$'\n'*) refuse "--result must be one line" ;; esac
  record | jq -e --arg s "$slug" '.picks[$s].pick == "do-it"' >/dev/null \
    || refuse "$slug is not a picked Atlas idea"
  record | jq --arg s "$slug" --arg gain "$gain" --arg result "$result" --arg at "$NOW" '
    .picks[$s] += {gain: ($gain == "yes"), result: $result, measured_at: $at}
  ' | write_record
  printf 'measured: %s gain=%s\n' "$slug" "$gain"
}

cmd_keep_test() {
  [ $# -eq 0 ] || refuse "keep-test takes no arguments"
  record | jq '
    (.builds[:2] | map(.built_at)) as $first
    | [.picks | to_entries[] | select(.value.pick == "do-it" and (.value.built_at as $b | $first | index($b) != null))
        | {slug: .key, text: .value.text, built_at: .value.built_at,
           result: (.value.result // null), gain: (.value.gain // null)}] as $picked
    | ([$picked[] | select(.gain == true)] | length) as $gains
    | {builds: $first, picked: $picked, measured_gains: $gains,
       verdict: (if ($picked | length) >= 2 and $gains >= 1 then "met"
         elif ($first | length) >= 2 and ($picked | length) < 2 then "not-met"
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

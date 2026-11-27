#!/usr/bin/env bash
# fm-effort-split.sh - where one week's shipped work went, by effort class.
#
# Usage:
#   fm-effort-split.sh [--week YYYY-Www] [--json]
#   fm-effort-split.sh -h | --help
#
# Fork patch (docs/fork-decisions/2026-11-27-effort-class-split.md). Reads the
# pull requests merged in one ISO week (Monday 00:00 to Sunday 23:59:59 UTC;
# default: the last full week before today) in every project registered in
# data/projects.md, and sorts each by the `Class: <word>` line of its body,
# which bin/fm-pr-class-lib.sh owns. A PR with no Class line, an unknown word,
# or two lines that disagree counts as `unclassified`; nothing is guessed, so
# PRs merged before the line existed are all unclassified.
#
# Each PR is counted once and by its added plus deleted lines, capped at 2,000
# a PR so one data file cannot swamp the week. Shares are of every merged PR
# except `sapna` ones, unclassified included, because the target is for the
# captain's own domain: sales plus cost at least 35 percent, fleet at most 30
# percent. The verdict is `fleet over target` when the fleet share by PR count
# is over 30 percent, else `fleet within target`; a week with no PR in that
# domain reads `no merged PRs`, and one where every such PR is unclassified
# reads `no classified PRs`. docs/task-lifecycle.md's queue-order rule cites
# that verdict.
#
# A project is read through its clone's origin (projects/<name>), which must
# be a GitHub repository; a project with no clone or another forge is named as
# skipped. Two registered names with one origin are read once.
#
# Output: one line, the Monday line the open-items sweep returns
# (noticed-queue skill). --json prints the same reading as one JSON object
# instead: week, range, projects, skipped, per-class count and capped lines,
# shares, and verdict.
# Exit 0: read. Exit 1: a registry, clone, or gh read failed, or a repository
# returned 1,000 PRs (gh's search cap), so the week cannot be read whole.
# Exit 2: bad usage. It reads only; it writes nothing.
set -eu

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-class-lib.sh
. "$SCRIPT_DIR/fm-pr-class-lib.sh"

LINE_CAP=2000
SALES_COST_TARGET=35
FLEET_MAX=30
SEARCH_CAP=1000

WEEK=
JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage 2>&1; exit 0 ;;
    --week)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      WEEK=$2
      shift 2
      ;;
    --json) JSON=true; shift ;;
    *) usage; exit 2 ;;
  esac
done
if [ -n "$WEEK" ] && ! [[ "$WEEK" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
  echo "error: --week takes an ISO week such as 2026-W47, not '$WEEK'" >&2
  exit 2
fi

die() { echo "error: $*" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || die "gh is not on PATH"
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"

# The week's label and its UTC bounds, as `<label> <start> <end>`.
RANGE=$(jq -nr --arg week "$WEEK" '
  def day: 86400;
  def midnight: strftime("%Y-%m-%dT00:00:00Z") | fromdate;
  def dow: strftime("%u") | tonumber;
  (if $week == "" then
     (now | midnight) as $today | $today - (($today | dow) - 1) * day - 7 * day
   else
     ($week[0:4] | tonumber) as $y | ($week[6:8] | tonumber) as $w
     | ("\($y)-01-04T00:00:00Z" | fromdate) as $jan4
     | $jan4 - (($jan4 | dow) - 1) * day + ($w - 1) * 7 * day
   end) as $mon
  | ($mon | strftime("%G-W%V")) as $label
  | if $week != "" and $label != $week then error("no such ISO week: \($week)") else . end
  | "\($label) \($mon | strftime("%Y-%m-%dT%H:%M:%SZ")) \($mon + 7 * day - 1 | strftime("%Y-%m-%dT%H:%M:%SZ"))"
' 2>/dev/null) || { echo "error: no such ISO week: $WEEK" >&2; exit 2; }
read -r LABEL START END <<< "$RANGE"

# host/owner/repo of a clone URL, lowercased: https, ssh:// and scp forms
# (the same reading as bin/fm-capture-land.sh's origin_repo).
origin_repo() {
  local u=$1
  u=${u%/}
  u=${u%.git}
  case "$u" in
    *://*) u=${u#*://} ;;
    *:*) u=${u%%:*}/${u#*:} ;;
  esac
  u=${u#*@}
  case "$u" in *:[0-9]*/*) u=${u%%:*}/${u#*/} ;; esac
  printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]'
}

REGISTRY="$DATA/projects.md"
[ -r "$REGISTRY" ] || die "cannot read the project registry $REGISTRY"

READ_NAMES=
SKIPPED=
SEEN=
ROWS=$(mktemp "${TMPDIR:-/tmp}/fm-effort-split.XXXXXX")
trap 'rm -f "$ROWS"' EXIT
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ ! -d "$PROJECTS/$name" ]; then
    SKIPPED="$SKIPPED${SKIPPED:+, }$name (no clone)"
    continue
  fi
  origin=$(git -C "$PROJECTS/$name" remote get-url origin 2>/dev/null) || {
    SKIPPED="$SKIPPED${SKIPPED:+, }$name (no origin)"
    continue
  }
  repo=$(origin_repo "$origin")
  host=${repo%%/*}
  slug=${repo#*/}
  fm_github_host_allowed "$host" || {
    SKIPPED="$SKIPPED${SKIPPED:+, }$name (not GitHub)"
    continue
  }
  case " $SEEN " in *" $repo "*) continue ;; esac
  SEEN="$SEEN $repo"
  json=$(GH_HOST=$host gh pr list --repo "$slug" --state merged \
    --search "merged:$START..$END" --limit "$SEARCH_CAP" \
    --json body,additions,deletions) \
    || die "could not read the merged PRs of $slug"
  count=$(printf '%s' "$json" | jq 'length') || die "unreadable PR list for $slug"
  [ "$count" -lt "$SEARCH_CAP" ] \
    || die "$slug returned $SEARCH_CAP merged PRs for $LABEL, gh's search cap, so the week cannot be read whole"
  # One row per PR: <class>\t<capped lines>.
  i=-1
  while i=$((i + 1)); [ "$i" -lt "$count" ]; do
    class=$(printf '%s' "$json" | jq -r --argjson i "$i" '.[$i].body // ""' | fm_pr_class_of_body) \
      || class=unclassified
    printf '%s\t%s\n' "$class" \
      "$(printf '%s' "$json" | jq -r --argjson i "$i" --argjson cap "$LINE_CAP" \
        '.[$i] | [(.additions // 0) + (.deletions // 0), $cap] | min')" >> "$ROWS"
  done
  READ_NAMES="$READ_NAMES${READ_NAMES:+, }$name"
done < <(awk '
  # A registry name runs from "- " to the first " [" or " - ", or to the end of
  # the line, as bin/fm-project-mode.sh matches it.
  substr($0, 1, 2) == "- " {
    name = substr($0, 3)
    cut = length(name) + 1
    i = index(name, " ["); if (i && i < cut) cut = i
    i = index(name, " - "); if (i && i < cut) cut = i
    name = substr(name, 1, cut - 1)
    if (name != "") print name
  }' "$REGISTRY")

# shellcheck disable=SC2016 # jq program text, not shell expansions
READING=$(jq -Rn \
  --arg week "$LABEL" --arg start "$START" --arg end "$END" \
  --arg projects "$READ_NAMES" --arg skipped "$SKIPPED" --arg words "$FM_PR_CLASS_WORDS unclassified" \
  --argjson cap "$LINE_CAP" --argjson target "$SALES_COST_TARGET" --argjson fleet_max "$FLEET_MAX" '
  [inputs | select(length > 0) | split("\t") | {class: .[0], lines: (.[1] | tonumber)}] as $prs
  | ($words | split(" ")) as $classes
  | (reduce $classes[] as $c ({}; .[$c] = {
        count: ([$prs[] | select(.class == $c)] | length),
        lines: ([$prs[] | select(.class == $c) | .lines] | add // 0)})) as $by
  | ([$prs[] | select(.class != "sapna")]) as $domain
  | ($domain | length) as $n
  | ([$domain[].lines] | add // 0) as $lines
  | def pct($part; $whole): if $whole == 0 then 0 else ($part * 100 / $whole | round) end;
  {
    week: $week, start: $start, end: $end,
    projects: ($projects | if . == "" then [] else split(", ") end),
    skipped: ($skipped | if . == "" then [] else split(", ") end),
    line_cap: $cap, prs: ($prs | length), domain_prs: $n,
    by_class: $by,
    shares: {
      sales_cost: {count: pct($by.sales.count + $by.cost.count; $n), lines: pct($by.sales.lines + $by.cost.lines; $lines)},
      fleet: {count: pct($by.fleet.count; $n), lines: pct($by.fleet.lines; $lines)},
      unclassified: {count: pct($by.unclassified.count; $n), lines: pct($by.unclassified.lines; $lines)}
    },
    target: {sales_cost_at_least: $target, fleet_at_most: $fleet_max},
    verdict: (if $n == 0 then "no merged PRs"
              elif $by.unclassified.count == $n then "no classified PRs"
              elif $by.fleet.count * 100 > $fleet_max * $n then "fleet over target"
              else "fleet within target" end)
  }' < "$ROWS")

if [ "$JSON" = true ]; then
  printf '%s\n' "$READING"
  exit 0
fi
printf '%s' "$READING" | jq -r '
  def nz: if . == "" then "none" else . end;
  "Effort split \(.week) (\(.start[0:10])..\(.end[0:10]) UTC; read \(.projects | join(", ") | nz)"
  + (if (.skipped | length) > 0 then "; skipped \(.skipped | join(", "))" else "" end)
  + "; \(.prs) merged PRs, \(.by_class.unclassified.count) unclassified): "
  + "sales+cost \(.shares.sales_cost.count)% of PRs, \(.shares.sales_cost.lines)% of capped lines (target at least \(.target.sales_cost_at_least)%); "
  + "fleet \(.shares.fleet.count)% of PRs, \(.shares.fleet.lines)% of capped lines (target at most \(.target.fleet_at_most)%): \(.verdict); "
  + "by class " + ([.by_class | to_entries[] | "\(.key) \(.value.count)"] | join(", "))
  + (if .by_class.sapna.count > 0 then " (sapna not in the shares)" else "" end)
'

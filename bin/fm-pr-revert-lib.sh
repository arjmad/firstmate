#!/usr/bin/env bash
# Whether a GitHub merge undoes work already landed on its base branch, read
# through gh's REST API so no clone is fetched. bin/fm-pr-merge.sh asks it
# before a merge and again about the merged commit.
#
# A green, mergeable pull request can still carry a head whose tree restores
# files to their content before a commit its base already holds: a branch
# rebased or reset onto the new base and then committed from a stale tree
# looks like an ordinary small change in its own commits while its diff undoes
# the landed work. A commit C counts as undone when some file C changed (its
# name or its rename source) is also in the change being checked and that
# file is identical at the checked tip and at C's first parent, so the tip
# holds it as it was before C. That reading is per file: a change that
# undoes only some of C's lines inside a file it also edits otherwise is not
# caught.
#
# The candidates are the commits reachable from a starting commit on the base
# branch whose committer date is at or after the window start, the earlier of
# the pull request's creation and the oldest author date among its own
# commits, so work that landed while the pull request was open is checked even
# when the branch was rebased past it. The 10 newest commits reachable from it
# are candidates too whatever their dates, but count as undone only when every
# file such a commit changed is undone, which is what a branch opened and
# committed afterwards from an older tree does; a later fix that restores only
# some of an earlier commit's files is left alone, while a deliberate whole
# revert of one is reported and only an attended waiver merges it. Before a merge the start is the merge
# base of the base branch and the head, whose ancestors are all on the base;
# after it, the base tip read before the merge, so the pull request's own
# commits are never candidates. A starting commit with more than 99
# candidates, or a compare whose file list reaches GitHub's 300-file cap,
# cannot be read completely and is reported unreadable rather than judged.
#
# Every function returns 0 once the question was answered, with
# FM_PR_REVERT_FOUND holding one line per undone commit (empty when none),
# and 1 when it could not be, with the reason in FM_PR_REVERT_ERROR.

FM_PR_REVERT_FOUND=
FM_PR_REVERT_ERROR=
FM_PR_REVERT_BASE_TIP=
FM_PR_REVERT_SINCE=
FM_PR_REVERT_MERGED=

# A GitHub file list on stdout, one path per line, for paths named by gh's
# filename and previous_filename fields. Args: endpoint, with --paginate first
# when the endpoint pages its files.
fm_pr_revert_list_files() {
  gh api "$@" --jq '(if type == "array" then .[] else .files[]? end) | .filename, (.previous_filename // empty)'
}

# The paths a pull request changes, read from its paginated file list.
# Args: owner/repo number
fm_pr_revert_pr_paths() {
  fm_pr_revert_list_files --paginate "repos/$1/pulls/$2/files"
}

# The paths a compare from the pre-merge base tip to the merged commit
# changes. Refuses a list at GitHub's cap. Args: owner/repo base merged
fm_pr_revert_compare_paths() {
  local out
  out=$(gh api "repos/$1/compare/$2...$3?per_page=1" \
    --jq '(.files | length | tostring), (.files[]? | .filename, (.previous_filename // empty))') || return 1
  [ "${out%%$'\n'*}" -lt 300 ] 2>/dev/null || return 1
  printf '%s\n' "$out" | tail -n +2
}

# The scan itself. Args: owner/repo tip from since paths-command...
# The paths command prints the change being checked, one path per line; it runs
# only when some candidate exists.
fm_pr_revert_scan() {
  local repo=$1 tip=$2 from=$3 since=$4 dir candidates line sha parent subject
  local count=0 cmp status n reverted recent
  shift 4
  FM_PR_REVERT_FOUND=
  FM_PR_REVERT_ERROR=
  if ! candidates=$(gh api "repos/$repo/commits?sha=$from&since=$since&per_page=100" \
    --jq '"count\t\(length)", (.[] | ["c", .sha, (.parents[0].sha // "-"), (.commit.message | split("\n")[0])] | @tsv)' 2>/dev/null); then
    FM_PR_REVERT_ERROR="the commits on the base branch since $since could not be read"
    return 1
  fi
  case "$candidates" in
    count$'\t'[0-9]*) count=${candidates%%$'\n'*}; count=${count#count$'\t'} ;;
    *) FM_PR_REVERT_ERROR="the commits on the base branch since $since could not be read"; return 1 ;;
  esac
  if [ "$count" -ge 100 ]; then
    FM_PR_REVERT_ERROR="100 or more commits landed on the base branch since $since, more than can be checked"
    return 1
  fi
  if ! recent=$(gh api "repos/$repo/commits?sha=$from&per_page=10" \
    --jq '.[] | ["r", .sha, (.parents[0].sha // "-"), (.commit.message | split("\n")[0])] | @tsv' 2>/dev/null); then
    FM_PR_REVERT_ERROR="the newest commits on the base branch could not be read"
    return 1
  fi
  candidates=$(printf '%s\n%s\n' "$candidates" "$recent" | awk -F '\t' '($1 == "c" || $1 == "r") && !seen[$2]++')
  [ -n "$candidates" ] || return 0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-revert.XXXXXX") || {
    FM_PR_REVERT_ERROR="no scratch directory could be made"
    return 1
  }
  if ! "$@" > "$dir/raw" 2>/dev/null; then
    rm -rf "$dir"
    FM_PR_REVERT_ERROR="the files of the change being checked could not be read"
    return 1
  fi
  LC_ALL=C sort -u "$dir/raw" > "$dir/change"
  while IFS=$'\t' read -r line sha parent subject; do
    case "$line" in c|r) ;; *) continue ;; esac
    if ! fm_pr_head_valid "$sha"; then
      FM_PR_REVERT_ERROR="the commits on the base branch since $since could not be read"
      break
    fi
    # A root commit has no earlier content to be restored to.
    [ "$parent" != - ] || continue
    if ! fm_pr_revert_list_files --paginate "repos/$repo/commits/$sha" > "$dir/raw" 2>/dev/null; then
      FM_PR_REVERT_ERROR="the files commit $sha changed could not be read"
      break
    fi
    LC_ALL=C sort -u "$dir/raw" > "$dir/files"
    LC_ALL=C comm -12 "$dir/files" "$dir/change" > "$dir/shared"
    [ -s "$dir/shared" ] || continue
    # An older commit counts only when the change touches every file it changed.
    [ "$line" = c ] || ! LC_ALL=C comm -23 "$dir/files" "$dir/change" | grep -q . || continue
    if ! cmp=$(gh api "repos/$repo/compare/$parent...$tip?per_page=1" \
      --jq '.status, (.files | length | tostring), (.files[]? | .filename, (.previous_filename // empty))' 2>/dev/null); then
      FM_PR_REVERT_ERROR="the change from $parent to $tip could not be read"
      break
    fi
    status=$(printf '%s\n' "$cmp" | sed -n 1p)
    n=$(printf '%s\n' "$cmp" | sed -n 2p)
    case "$status" in
      ahead|identical) ;;
      *)
        FM_PR_REVERT_ERROR="$tip does not descend from $parent (compare status \"$status\")"
        break
        ;;
    esac
    if ! [ "$n" -lt 300 ] 2>/dev/null; then
      FM_PR_REVERT_ERROR="the change from $parent to $tip reaches GitHub's 300-file compare cap"
      break
    fi
    printf '%s\n' "$cmp" | tail -n +3 | LC_ALL=C sort -u > "$dir/differs"
    LC_ALL=C comm -23 "$dir/shared" "$dir/differs" > "$dir/undone"
    [ -s "$dir/undone" ] || continue
    [ "$line" = c ] || cmp -s "$dir/undone" "$dir/files" || continue
    reverted=$(wc -l < "$dir/undone" | tr -d ' ')
    FM_PR_REVERT_FOUND="$FM_PR_REVERT_FOUND${sha:0:12} $subject ($reverted file(s) back to their content before it: $(head -n 3 "$dir/undone" | paste -sd ',' - | sed 's/,/, /g')$([ "$reverted" -le 3 ] || printf ', and %s more' "$((reverted - 3))"))
"
  done <<EOF
$candidates
EOF
  rm -rf "$dir"
  if [ -n "$FM_PR_REVERT_ERROR" ]; then
    FM_PR_REVERT_FOUND=
    return 1
  fi
  return 0
}

# Before a merge: whether merging the pull request at its verified head undoes
# landed work. Also sets FM_PR_REVERT_BASE_TIP and FM_PR_REVERT_SINCE for
# fm_pr_revert_check_merged. Args: owner/repo number base-branch head
fm_pr_revert_check_pr() {
  local repo=$1 number=$2 base=$3 head=$4 created window merge_base base_tip oldest
  FM_PR_REVERT_FOUND=
  FM_PR_REVERT_ERROR=
  FM_PR_REVERT_BASE_TIP=
  FM_PR_REVERT_SINCE=
  if ! created=$(gh api "repos/$repo/pulls/$number" --jq '.created_at // ""' 2>/dev/null) \
    || ! [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]; then
    FM_PR_REVERT_ERROR="the pull request's creation time could not be read"
    return 1
  fi
  if ! window=$(gh api "repos/$repo/compare/$base...$head" \
    --jq '[(.merge_base_commit.sha // ""), (.base_commit.sha // ""), ([.commits[]?.commit.author.date | strings] | min // "")] | @tsv' 2>/dev/null); then
    FM_PR_REVERT_ERROR="the merge base of $base and $head could not be read"
    return 1
  fi
  IFS=$'\t' read -r merge_base base_tip oldest <<EOF
$window
EOF
  if ! fm_pr_head_valid "$merge_base" || ! fm_pr_head_valid "$base_tip"; then
    FM_PR_REVERT_ERROR="the merge base of $base and $head could not be read"
    return 1
  fi
  FM_PR_REVERT_SINCE=$created
  if [[ "$oldest" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && [[ "$oldest" < "$created" ]]; then
    FM_PR_REVERT_SINCE=$oldest
  fi
  FM_PR_REVERT_BASE_TIP=$base_tip
  fm_pr_revert_scan "$repo" "$head" "$merge_base" "$FM_PR_REVERT_SINCE" \
    fm_pr_revert_pr_paths "$repo" "$number"
}

# After a merge: whether the merged commit undoes work landed on the base tip
# that fm_pr_revert_check_pr read. Args: owner/repo number
fm_pr_revert_check_merged() {
  local repo=$1 number=$2 merged
  FM_PR_REVERT_FOUND=
  FM_PR_REVERT_ERROR=
  if ! fm_pr_head_valid "$FM_PR_REVERT_BASE_TIP" || [ -z "$FM_PR_REVERT_SINCE" ]; then
    FM_PR_REVERT_ERROR="no pre-merge base tip was read"
    return 1
  fi
  if ! merged=$(gh api "repos/$repo/pulls/$number" --jq '.merge_commit_sha // ""' 2>/dev/null) \
    || ! fm_pr_head_valid "$merged"; then
    FM_PR_REVERT_ERROR="the merged commit could not be read"
    return 1
  fi
  # shellcheck disable=SC2034 # read by the sourcing script
  FM_PR_REVERT_MERGED=$merged
  fm_pr_revert_scan "$repo" "$merged" "$FM_PR_REVERT_BASE_TIP" "$FM_PR_REVERT_SINCE" \
    fm_pr_revert_compare_paths "$repo" "$FM_PR_REVERT_BASE_TIP" "$merged"
}

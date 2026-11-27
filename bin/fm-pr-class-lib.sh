# shellcheck shell=bash
# fm-pr-class-lib.sh - the one-word effort class a ship's PR body carries.
# Usage: . bin/fm-pr-class-lib.sh
#
# Fork patch (docs/fork-decisions/2026-11-27-effort-class-split.md). Every
# ship PR body carries one line naming the kind of work it is, so a weekly
# reader can show where the fleet's shipped effort went:
#
#   Class: <word>
#
# The word is one of FM_PR_CLASS_WORDS below; fm_pr_class_glossary prints what
# each one covers, and that text is the one definition the ship brief hands its
# worker. Only a line that opens with `Class:` counts, after any leading list
# or quote marker and `**` or backtick emphasis, so a mid-sentence mention is
# ignored; the word is read case-insensitively.
#
# The ship brief's Definition of done (bin/fm-dod-lib.sh, direct-PR block)
# writes the instruction on a line that opens with FM_PR_CLASS_BRIEF_MARKER.
# bin/fm-pr-merge.sh refuses a PR without a valid Class line only for a task
# whose data/<id>/brief.md holds that marker line, so a ship briefed before the
# line existed, a capture or other machine PR with no scaffold brief, and a
# no-mistakes or local-only ship all merge as before.
# bin/fm-effort-split.sh is the weekly reader.
#
# This file defines functions and constants only.

FM_PR_CLASS_WORDS="sales cost run time fleet sapna personal"
FM_PR_CLASS_BRIEF_MARKER="Effort class:"

# fm_pr_class_glossary: one line per class word, `<word> - <what it covers>`,
# in FM_PR_CLASS_WORDS order.
fm_pr_class_glossary() {
  cat <<'EOF'
sales - grows sales: listings, titles, images, A+, ads, bids, budgets, prices, deals, coupons, promotions, catalog, customer-visible site changes
cost - cuts cost or saves cash: FBA fees, SIPP, reimbursements, carrier claims, money-losing SKUs
run - keeps the business running: labels, packet, mail, orders, inventory, finance, records, and business plumbing such as the runner, monitors, sync and CLI
time - saves the captain's time: Launchpad, Docs, Telegram cards, notifications, helm-first routing
fleet - fleet upkeep: fleet, firstmate, skills, brain and harness repos, and code health in business repos (audits, fix waves, tests, gates, deps, agent docs)
sapna - Sapna and Nova work
personal - home and the captain's own machines: Home Assistant, home network, household money, his desktops
EOF
}

# fm_pr_class_valid <word>: succeed for one of FM_PR_CLASS_WORDS.
fm_pr_class_valid() {
  local word
  for word in $FM_PR_CLASS_WORDS; do
    [ "${1:-}" != "$word" ] || return 0
  done
  return 1
}

# fm_pr_class_of_body: read a PR body on stdin and print its class.
# Exit 0 prints the word; exit 1 prints nothing (no Class line); exit 2 prints
# the offending value, an unknown word or the distinct words of Class lines
# that disagree, joined by `/`.
fm_pr_class_of_body() {
  local values word bad=
  values=$(awk '
    {
      sub(/\r$/, "")
      line = $0
      gsub(/\*\*|`/, "", line)
      sub(/^[[:space:]]+/, "", line)
      while (line ~ /^[>*+-][[:space:]]/) sub(/^[>*+-][[:space:]]+/, "", line)
      if (line !~ /^[Cc][Ll][Aa][Ss][Ss]:/) next
      sub(/^[^:]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      sub(/[.;]$/, "", line)
      v = tolower(line)
      if (v == "") v = "<empty>"
      if (!seen[v]++) print v
    }
  ')
  [ -n "$values" ] || return 1
  if [ "$(printf '%s\n' "$values" | wc -l)" -gt 1 ]; then
    printf '%s\n' "$values" | paste -sd/ -
    return 2
  fi
  word=$values
  fm_pr_class_valid "$word" || bad=1
  printf '%s\n' "$word"
  [ -z "$bad" ] || return 2
}

# fm_pr_class_brief_requires <brief-file>: succeed when the brief carries the
# scaffold's Class instruction (a line opening with FM_PR_CLASS_BRIEF_MARKER).
# A missing or unreadable brief requires nothing.
fm_pr_class_brief_requires() {
  [ -f "${1:-}" ] && [ -r "$1" ] || return 1
  grep -q "^$FM_PR_CLASS_BRIEF_MARKER " "$1" 2>/dev/null
}

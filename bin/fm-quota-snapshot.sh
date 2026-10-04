#!/usr/bin/env bash
# fm-quota-snapshot.sh - the dispatch quota read, taken from the account
# Claude workers actually run on.
#
# Usage: bin/fm-quota-snapshot.sh [--json]
#
# Without a Claude worker account pin ($FM_HOME/config/claude-account, owned by
# bin/fm-worker-account-lib.sh) this is exactly `quota-axi` or
# `quota-axi --json`, unchanged.
#
# With a pin, an ambient quota-axi read measures whichever Claude login the
# caller's environment selects, which is not the pinned worker account, so
# dispatch would rank Claude candidates on another account's numbers. This
# script therefore runs quota-axi with CLAUDE_CONFIG_DIR set to the pinned root
# (unset for `ordinary`), so its Claude row can only describe the pinned
# account or report it unavailable. A pinned root whose login lives in the
# macOS Keychain reads as unavailable there, because quota-axi will not prompt
# for Keychain access. When the Claude row is not measured, the script asks
# Claude Code itself (`claude -p /usage` under the pinned root, the same
# precedence-shedding environment a pinned launch uses), which reads the
# login without a prompt:
#   --json  replaces the Claude row(s) with one row built from that reading:
#           all_models is bounded by the session and all-model week windows,
#           and each named-model week adds a model:<name> row bounded by
#           all_models too. Runway is unknown and no spendPriority is
#           published, so dispatch keeps the candidate eligible but unranked
#           with the true remaining percentage, never another account's.
#   TOON    prints quota-axi's TOON, then a pinned_claude block with the same
#           remaining percentages.
# When that reading also fails, the quota-axi output stands as is: the Claude
# row stays unmeasured, which dispatch already treats as disclosed uncertainty.
#
# Exit status is quota-axi's; 2 for usage or pin errors.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_QUOTA_CLAUDE_USAGE_SECONDS=${FM_QUOTA_CLAUDE_USAGE_SECONDS:-30}

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

JSON=0
case "${1:-}" in
  '') ;;
  --json) JSON=1 ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-quota-snapshot.sh [--json]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: fm-quota-snapshot.sh [--json]" >&2; exit 2; }

pin=$(fm_worker_account_resolve claude "$CONFIG") || exit 2
if [ -z "$pin" ]; then
  if [ "$JSON" = 1 ]; then exec quota-axi --json; else exec quota-axi; fi
fi
root=$(printf '%s\n' "$pin" | cut -f2)

# The pinned environment: the selected root, with every credential Claude
# ranks above a root's stored login shed, as a pinned launch does.
pinned=(env)
for name in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do pinned+=(-u "$name"); done
if [ -n "$root" ]; then pinned+=("CLAUDE_CONFIG_DIR=$root"); else pinned+=(-u CLAUDE_CONFIG_DIR); fi

# Prints one JSON object of remaining percentages from `claude -p /usage`:
# {"session":N,"week":N,"models":{"<name>":N}}; returns 1 when unreadable.
claude_usage() {
  local text
  command -v claude >/dev/null 2>&1 || return 1
  text=$(fm_run_timed "$FM_QUOTA_CLAUDE_USAGE_SECONDS" "${pinned[@]}" \
    claude -p /usage 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$text" | perl -ne '
    BEGIN { %m = () }
    if (/^\s*Current session:\s*(\d+)% used/) { $s = 100 - $1 }
    elsif (/^\s*Current week \(all models\):\s*(\d+)% used/) { $w = 100 - $1 }
    elsif (/^\s*Current week \(([^)]+)\):\s*(\d+)% used/) { $m{lc $1} = 100 - $2 }
    END {
      exit 1 unless defined $w;
      $s = 100 unless defined $s;
      print "{\"session\":$s,\"week\":$w,\"models\":{",
        join(",", map { my $k = $_; $k =~ s/[^a-z0-9.-]/-/g; "\"$k\":$m{$_}" } sort keys %m), "}}\n";
    }'
}

if [ "$JSON" = 0 ]; then
  "${pinned[@]}" quota-axi
  rc=$?
  if usage=$(claude_usage); then
    printf '%s\n' "$usage" | jq -r --arg pin "${root:-ordinary}" '
      ([.session, .week] | min) as $all |
      "pinned_claude: worker account \($pin) via claude -p /usage; supersedes the claude row above; runway unknown, no spendPriority",
      "  all_models: \($all)% remaining (session \(.session)%, week \(.week)%)",
      (.models | to_entries[] | "  model:\(.key): \([$all, .value] | min)% remaining (week \(.value)%)")
    '
  fi
  exit "$rc"
fi

snapshot=$("${pinned[@]}" quota-axi --json)
rc=$?
[ "$rc" = 0 ] || { printf '%s\n' "$snapshot"; exit "$rc"; }
measured=$(printf '%s\n' "$snapshot" | jq -r '
  [.providers[]? | select(.provider == "claude") | .quotaSemantics.status] |
  if length > 0 and all(. == "known" or . == "partial") then "yes" else "no" end' 2>/dev/null)
if [ "$measured" = yes ] || ! usage=$(claude_usage); then
  printf '%s\n' "$snapshot"
  exit 0
fi
printf '%s\n' "$snapshot" | jq --argjson u "$usage" '
  ([$u.session, $u.week] | min) as $all |
  def row($scope; $pct):
    {scope: $scope, status: "known", effectivePercentRemaining: $pct, runway: {status: "unknown"}};
  ({provider: "claude", label: "Claude", source: "claude-usage",
   state: {status: "fresh"},
   quotaSemantics: {status: "known", effectiveAvailability:
     ([row("all_models"; $all)] +
      [$u.models | to_entries[] | row("model:\(.key)"; ([$all, .value] | min))])}}
  + (if .schemaVersion == 6 then {accountKey: "default"} else {} end)) as $row |
  .providers |= ((map(select(.provider != "claude"))) + [$row])
'

#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# They hold the affected-shard planning wiring: every job that consumes the
# plan job's output runs a gate step after its checkout and gates every later
# step on it, label events other than full-ci run nothing under prefixed
# names in their own non-cancelling group, and full-ci and workflow_dispatch
# run every job. What the plan selects is tests/fm-ci-plan.test.sh's subject.
#
# They also hold the fork opt-out: the repository variables FM_CI_SKIP_PUSH and
# FM_CI_SKIP_MACOS let a fork skip the push run and the macOS job through a
# job-level condition, while with neither set every job runs exactly as before.
#
# The workflow is parsed as YAML and its concurrency and job-level `if`
# expressions are resolved against simulated pull_request and push contexts,
# so the assertions describe what GitHub would do, not how the file happens
# to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups, the status functions, !, ==, !=, &&,
# ||, and parentheses - against a simulated context hash, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success. Each ruby -e below prepends this so every resolver shares one
# evaluator.
# shellcheck disable=SC2016  # the ${{ }} below is Ruby text, not a shell expansion
EXPRESSION_RUBY='
require "strscan"
class Expression
  def self.evaluate(source, context)
    new(source, context).parse
  end

  STATUS_FUNCTIONS = %w[always() success() failure() cancelled()].freeze

  # A job or step `if` is a bare expression or one wrapped in ${{ }}, an
  # absent condition means the job runs, and a condition that calls no status
  # function gets the implicit success() check GitHub documents.
  def self.condition(raw, context)
    source = raw.to_s.strip
    source = Regexp.last_match(1) if source =~ /\A\$\{\{(.*)\}\}\z/m
    source = "success()" if source.empty?
    source = "success() && (#{source})" unless new(source, context).status_check?
    truthy?(evaluate(source, context))
  end

  # A result is truthy unless it is false, nil, or the empty string.
  def self.truthy?(value)
    value != false && !value.nil? && value != ""
  end

  def initialize(source, context)
    @context = context
    @tokens = []
    scanner = StringScanner.new(source)
    until scanner.eos?
      next if scanner.skip(/\s+/)
      if scanner.scan(/\x27([^\x27]*)\x27/) then @tokens << [:string, scanner[1]]
      elsif scanner.scan(/\|\||&&|==|!=|[()!]/) then @tokens << [:operator, scanner.matched]
      elsif scanner.scan(/[A-Za-z_][\w.\-]*(?:\(\))?/) then @tokens << [:name, scanner.matched]
      else raise "unsupported expression syntax at: #{scanner.rest}"
      end
    end
  end

  def status_check?
    @tokens.any? { |kind, value| kind == :name && STATUS_FUNCTIONS.include?(value) }
  end

  def parse
    result = parse_or
    raise "unexpected trailing token: #{@tokens.first.inspect}" unless @tokens.empty?
    result
  end

  private

  def take?(operator)
    return false unless @tokens.first == [:operator, operator]
    @tokens.shift
    true
  end

  def parse_or
    left = parse_and
    while take?("||")
      right = parse_and
      left = Expression.truthy?(left) ? left : right
    end
    left
  end

  def parse_and
    left = parse_comparison
    while take?("&&")
      right = parse_comparison
      left = Expression.truthy?(left) ? right : left
    end
    left
  end

  def parse_comparison
    left = parse_unary
    loop do
      operator = ["==", "!="].find { |candidate| take?(candidate) } or break
      right = parse_unary
      unless left.class == right.class
        raise "the resolver only compares operands of one type: #{left.inspect} #{operator} #{right.inspect}"
      end
      equal = left.is_a?(String) ? left.casecmp?(right) : left == right
      left = operator == "==" ? equal : !equal
    end
    left
  end

  def parse_unary
    return !Expression.truthy?(parse_unary) if take?("!")
    parse_primary
  end

  def parse_primary
    if take?("(")
      inner = parse_or
      raise "missing closing parenthesis" unless take?(")")
      return inner
    end
    kind, value = @tokens.shift
    raise "expected an operand, got #{kind.inspect}" unless kind == :string || kind == :name
    return value if kind == :string
    if STATUS_FUNCTIONS.include?(value)
      status = @context.fetch("needs.status", "success")
      return value == "always()" || value == "#{status}()"
    end
    raise "unresolvable context reference: #{value}" unless @context.key?(value)
    @context.fetch(value)
  end
end
'

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3 action=${4:-} label=${5:-}
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
  "github.event.action" => ARGV[4],
  "github.event.label.name" => ARGV[5],
}

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { Expression.evaluate(Regexp.last_match(1), context).to_s }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id" "$action" "$label"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated event and fork variable setting; an unset
# repository variable reads as the empty string, as GitHub documents.
jobs_running_under() {  # <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS> [<action> <label>]
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[1],
  "vars.FM_CI_SKIP_PUSH" => ARGV[2],
  "vars.FM_CI_SKIP_MACOS" => ARGV[3],
  "github.event.action" => ARGV[4],
  "github.event.label.name" => ARGV[5],
}
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$1" "$2" "$3" "${4:-}" "${5:-}"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='plan test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly three
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 3 ] \
    || fail "ci.yml must carry exactly three distinct job timeouts (fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always() && steps.gate.outputs.run == \x27true\x27"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

# The fork opt-out is opt-in: with neither variable set every job runs on both
# events, FM_CI_SKIP_PUSH=1 empties only the push run, and FM_CI_SKIP_MACOS=1
# removes only the macOS job. A "-" in the table means the variable is unset.
test_fork_skip_variables_are_opt_in() {
  local all event skip_push skip_macos expected want actual
  all=$(workflow_jobs) || fail "could not list ci.yml jobs"
  printf '%s\n' "$all" | grep -qx macos-stock-bash \
    || fail "the macOS job is missing from ci.yml, so the table below would prove nothing"
  while read -r event skip_push skip_macos expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$skip_macos" != - ] || skip_macos=
    case $expected in
      all) want=$all ;;
      none) want= ;;
      all-but-macos) want=$(printf '%s\n' "$all" | grep -vx macos-stock-bash) ;;
      *) fail "unknown expectation $expected" ;;
    esac
    actual=$(jobs_running_under "$event" "$skip_push" "$skip_macos") \
      || fail "could not resolve the job conditions for $event FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos"
    [ "$actual" = "$want" ] \
      || fail "$event with FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos must run $expected jobs"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$want" | tr '\n' ' ')"
  done <<'TABLE'
push         - - all
pull_request - - all
push         1 - none
pull_request 1 - all
pull_request - 1 all-but-macos
push         - 1 all-but-macos
TABLE
  pass "the fork skip variables change nothing unless set, and each skips only its own run or job"
}

# Print true or false: whether one job's job-level `if` resolves true under
# one simulated event, fork variable setting, and outcome of its needed jobs.
job_runs_under() {  # <job> <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS> <needs status>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[2],
  "vars.FM_CI_SKIP_PUSH" => ARGV[3],
  "vars.FM_CI_SKIP_MACOS" => ARGV[4],
  "needs.status" => ARGV[5],
  "github.event.action" => "",
  "github.event.label.name" => "",
}
puts Expression.condition(YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])["if"], context)
' "$CI_WORKFLOW" "$@"
}

# The aggregate must keep running after a failed lane so its timing summary
# still lands, while the push skip still removes it from a skipped push run.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event skip_push expected actual
  while read -r event skip_push expected; do
    [ "$skip_push" != - ] || skip_push=
    actual=$(job_runs_under tests-timing-aggregate "$event" "$skip_push" '' failure) \
      || fail "could not resolve the aggregate condition for $event FM_CI_SKIP_PUSH=$skip_push"
    [ "$actual" = "$expected" ] \
      || fail "after a failed lane, the aggregate on $event with FM_CI_SKIP_PUSH=$skip_push must resolve $expected, got $actual"
  done <<'TABLE'
pull_request - true
push         - true
push         1 false
TABLE
  pass "the timing aggregate still runs after a failed lane unless the push run is skipped"
}

test_label_events_get_their_own_group_unless_full_ci() {
  local push labeled full
  push=$(resolve_concurrency pull_request 108 900001 synchronize '') || fail "could not resolve PR concurrency"
  labeled=$(resolve_concurrency pull_request 108 900002 labeled docs) || fail "could not resolve label concurrency"
  full=$(resolve_concurrency pull_request 108 900003 labeled full-ci) || fail "could not resolve full-ci concurrency"
  [ "$(group_of "$labeled")" != "$(group_of "$push")" ] \
    || fail "an unrelated label event must not share the PR's group"
  [ "$(cancel_of "$labeled")" = false ] || fail "an unrelated label event must cancel nothing"
  [ "$(group_of "$full")" = "$(group_of "$push")" ] || fail "adding full-ci must join the PR's group"
  [ "$(cancel_of "$full")" = true ] || fail "adding full-ci must supersede the PR's running suite"
  pass "an unrelated label gets its own non-cancelling group, and full-ci supersedes the PR's run"
}

test_label_events_run_all_or_nothing_under_prefixed_names() {
  local all actual
  all=$(workflow_jobs) || fail "could not list ci.yml jobs"
  printf '%s\n' "$all" | grep -qx plan || fail "the plan job is missing from ci.yml"
  actual=$(jobs_running_under pull_request '' '' labeled docs) || fail "could not resolve the label conditions"
  [ -z "$actual" ] || fail "an unrelated label event must run no job, ran: $(printf '%s' "$actual" | tr '\n' ' ')"
  actual=$(jobs_running_under pull_request '' '' labeled full-ci) || fail "could not resolve the full-ci conditions"
  [ "$actual" = "$all" ] || fail "a full-ci label event must run every job"
  actual=$(jobs_running_under workflow_dispatch '' '') || fail "could not resolve the dispatch conditions"
  [ "$actual" = "$all" ] || fail "workflow_dispatch must run every job"
  ruby -ryaml -e "$EXPRESSION_RUBY" - "$CI_WORKFLOW" <<'RUBY' || fail "label name prefix contract"
YAML.load_file(ARGV[0]).fetch("jobs").each do |id, job|
  name = job.fetch("name")
  prefix = name[/\A\$\{\{(.+?)\}\}/, 1] or raise "#{id} has no name prefix expression"
  rest = name.sub(/\A\$\{\{.+?\}\}/, "")
  raise "#{id} keeps no own name after its prefix" if rest.strip.empty?
  [["labeled", "docs", "Not run for label - "], ["labeled", "full-ci", ""], ["synchronize", "", ""]].each do |action, label, want|
    got = Expression.evaluate(prefix, {"github.event.action" => action, "github.event.label.name" => label}).to_s
    raise "#{id} prefix under #{action} #{label.inspect} is #{got.inspect}, wanted #{want.inspect}" unless got == want
  end
end
RUBY
  pass "full-ci and workflow_dispatch run every job, and any other label runs none under prefixed names"
}

test_plan_consumers_gate_every_later_step() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "plan gate contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
consumers = jobs.select { |_, job| Array(job["needs"]).include?("plan") }
expected = %w[lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial tests-herdr macos-stock-bash]
raise "plan consumers are #{consumers.keys.sort}, wanted #{expected.sort}" unless consumers.keys.sort == expected.sort
consumers.each do |id, job|
  steps = job.fetch("steps")
  raise "#{id} must check out first" unless steps[0]["uses"].to_s.start_with?("actions/checkout@")
  gate = steps[1]
  raise "#{id} must run the plan gate second" unless gate["id"] == "gate" && gate["run"].to_s.include?("bin/fm-ci-plan.sh gate")
  raise "#{id} gate must read the plan job output" unless gate.dig("env", "FM_CI_PLAN") == "${{ needs.plan.outputs.plan }}"
  steps[2..].each do |step|
    cond = step["if"].to_s
    label = step["name"] || step["uses"]
    next if cond == "steps.gate.outputs.run != 'true'"
    unless cond == "steps.gate.outputs.run == 'true'" || cond == "always() && steps.gate.outputs.run == 'true'"
      raise "#{id} step #{label.inspect} is not gated (if: #{cond.inspect})"
    end
  end
  runs = steps.select { |step| step["run"].to_s.include?("bin/fm-test-run.sh") }
  runs.each do |step|
    raise "#{id} behavior run must pass the gate's only list" unless step["run"].include?('${FM_CI_ONLY:+--only "$FM_CI_ONLY"}') && step.dig("env", "FM_CI_ONLY") == "${{ steps.gate.outputs.only }}"
  end
end
RUBY
  pass "every plan consumer gates each step after its checkout and gate, and behavior lanes pass the selected scripts"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_label_events_get_their_own_group_unless_full_ci
test_label_events_run_all_or_nothing_under_prefixed_names
test_plan_consumers_gate_every_later_step
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_fork_skip_variables_are_opt_in
test_timing_aggregate_still_runs_after_a_failed_lane
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop

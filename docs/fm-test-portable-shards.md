# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.
`tests/fm-test-ci-timings.tsv` holds the committed per-script CI duration hints the packer reads.

## Verification inputs

Balance hints come from successful Ubuntu CI samples, not from local runs.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The committed table records the slowest successful `duration_ms` per `tests/*.test.sh` across green main CI runs [43359484992](https://github.com/kunchenguid/firstmate/actions/runs/43359484992), [43331691300](https://github.com/kunchenguid/firstmate/actions/runs/43331691300), and [43209319634](https://github.com/kunchenguid/firstmate/actions/runs/43209319634), refreshed 2026-11-13.
Failed or cancelled scripts are ignored, so a timeout does not become a packing weight.

This fork keeps the slower of each upstream row and the fork's own slowest successful CI sample for every script both measured, and the fork's own sample for its fork-only scripts, so the modeled budget holds against the fork's runners; the file header says the same.
Those fork samples are the serial and parallel hint tables `bin/fm-test-run.sh` carried before the 2026-11-28 sync moved the hints into the timings file: serial artifacts of green fork runs from [36500320998](https://github.com/arjmad/firstmate/actions/runs/36500320998) (2026-10-01) through [41869728885](https://github.com/arjmad/firstmate/actions/runs/41869728885) (2026-11-04), and two-wide parallel artifacts of eight green fork runs from [42913949765](https://github.com/arjmad/firstmate/actions/runs/42913949765) to [43074988852](https://github.com/arjmad/firstmate/actions/runs/43074988852) (2026-11-11).
Fork samples taken while the fork was private ran on the slower 2-vCPU runner, so they are upper estimates until fork CI measures them again.
Refresh from timing artifacts of the repository whose runners execute the lane, with `gh-axi run download <run-id> -R <owner>/firstmate`.
Observed maxima provide conservative packing weights, not an upper bound on future durations.
A passing coverage guard does not establish a healthy job duration; refresh the table from uploaded timing artifacts when a member grows or the lane gains scripts.

The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains a separate measurement and is skipped by the portable CI shards.
Measure that script through the focused Git Bash runner rather than a portable skip.

A timed-out shard may upload no artifact, so a complete green run is what keeps the slowest scripts measured in the shard that needs them most.

The 2026-11-13 `tests/fm-pi-bash-timeout.test.sh` serial hint is a provisional local measurement of 1486 ms, the slowest of five successful `bin/fm-test-run.sh tests/fm-pi-bash-timeout.test.sh` samples (1288-1486 ms) on a macOS arm64 host, collected separately from coverage and lint checks.
Replace it with an Ubuntu timing-artifact maximum at the next CI refresh; this is not whole-shard CI timing evidence.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over the committed hints.
CI runs each lane with `--jobs 2`, so wall time tracks the longest member rather than the sequential sum.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime; both parallel jobs install the Pi package and fail on that gate skip so a packed move cannot silently skip it.
Read the derived packing estimates with `bin/fm-test-run.sh --check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve committed-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `tests/fm-test-ci-timings.tsv` whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

`portable-serial-<k>of<n>` splits the remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` (currently 23 in this fork, 19 upstream) and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over the committed duration hints.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
The packing target is 15 minutes (`serial_budget_ms=900000`).
`--check-coverage` refuses a modeled multi-script shard above that target; an indivisible suite may occupy a shard alone when its own hint is already above 15 minutes.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget, a singleton overflow, and refusal of a multi-script overflow through the executable runner.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
The timing-aggregate job then runs `bin/fm-ci-budget-warn.sh`, which emits a GitHub warning annotation (never a failure) when any lane or lint partition's measured command time is at or above 20 minutes.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns the canonical CI partitions; upstream runs four, and this fork's `ci.yml` selects eight, one worker each (the lint job's own comment owns that evidence).
Each partition attempts full source-aware ShellCheck analysis and runs workflow validation and backend-purity checks.
Upstream's pull requests pass `--changed` so only the canonical-set files changed since the merge-base are analyzed, upgrading to the full set for lint definition files and broadly sourced helpers.
This fork does not pass `--changed` in CI: its affected-shard plan below already runs only the canonical partitions that hold an affected root, and each of those runs whole, so a `--changed` split of only the changed roots would disagree with the plan about which job owns a root.
Main pushes keep the full canonical gate.
CI caches the pinned ShellCheck and actionlint binaries and skips the download when the pin is already present.
`FM_LINT_JOBS=1` stays in force because a second concurrent ShellCheck process does not fit the hosted runner's memory envelope.

CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots for two, four and eight partitions, `--changed` source-aware analysis, definition-file upgrades, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.

The packing target is a complete green run under fifteen minutes including start delay.
One indivisible serial suite (`tests/fm-remote-secondmate-lifecycle-e2e.test.sh`) currently measures above that target on its own; it occupies a singleton shard rather than raising the job timeout. It is one sequential fixture lifecycle, not independently invocable cases, so splitting it would re-run provision/seed/launch per file and change how the lifecycle is asserted.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
This fork's layout uses twenty-three serial jobs, two parallel jobs with `--jobs 2`, eight lint partitions, Herdr, herdr-core, plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
The workflow retains per-PR supersession and keeps only the newest of close main pushes' runs, without changing the compliance workflow's event semantics.

## Affected-shard planning

A pull request runs only the CI work its change touches, and a draft runs none of it until it is marked ready ([`CONTRIBUTING.md`](../CONTRIBUTING.md#development) describes the draft flow).
The `CI plan` job runs `bin/fm-ci-plan.sh plan`, which records the behavior scripts `bin/fm-test-run.sh --changed` selects and the lint roots whose analysis can see a changed file.
Every lint partition, behavior lane, the Herdr lane and the macOS job keep their check names, run `bin/fm-ci-plan.sh gate` after checkout, and no-op every later step when nothing they own is affected, so an unaffected check still reports success.
A touched behavior lane runs only its selected scripts through `bin/fm-test-run.sh --only`; a touched lint partition runs whole.
A `workflow_dispatch` given a `base` ref plans the dispatched branch against that ref as a pull request would, so a branch's plan can be tried on GitHub before it has a pull request.
Pushes, `workflow_dispatch` without a `base` input, the `full-ci` label, CI configuration, shared libraries, broadly sourced files, more than 25 changed files, deletions under `bin/` or `tests/`, and unmapped paths run the full suite instead.
The script header owns the plan format, the full-suite rules, their measured thresholds, and the gate contract; `tests/fm-ci-plan.test.sh` and `tests/fm-ci-workflow.test.sh` hold them.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate, Ready for review verdict, Full suite verdict | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.

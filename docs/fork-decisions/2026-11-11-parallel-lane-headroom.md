2026-11-11: Arjun routed the fix for CI's "Behavior portable parallel 2" lane, which had run 25 to 30 minutes against its 30-minute cap since 2026-11-10, so it timed out or was cancelled near the bound and failed "Full suite" with it.
Decision: refresh every parallel hint from fork CI, repack the two lanes by longest-processing-time, and run each lane's members two at a time with `--jobs 2`; the cap stays at 30 minutes and no job is added.
Why: the members had grown to about 57 minutes of one-at-a-time work, with `tests/fm-captain-hold-lifecycle.test.sh` at up to 16 minutes and `tests/fm-pr-merge.test.sh` at up to 13, so even a perfect two-lane split needs about 28.5 minutes per lane; every member is proven isolated, so two-wide execution brings each lane to about 16 and 14 minutes of test time.
Upstream runs its parallel lanes one at a time with its own hints, so this is a fork patch.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Parallel hints refreshed from fork CI, lanes repacked, and each parallel CI lane runs two-wide | `bin/fm-test-run.sh` (`portable_parallel_weight_hints`, `list_portable_parallel_1`, `list_portable_parallel_2`), `.github/workflows/ci.yml` (`--jobs 2` on both parallel lanes), `docs/fm-test-portable-shards.md` "Parallel lanes" | `bin/fm-test-run.sh`, `.github/workflows/ci.yml`, `docs/fm-test-portable-shards.md` | carried | c8d8fdad |

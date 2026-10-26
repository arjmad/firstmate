PR: #90

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Quota chooses the candidate for ready work, never whether or when it runs: no deferring, holding, or staggering ready work to save quota; a quota stop (a floor, or a runway that fails `quota-array-dispatch`'s feasibility gate) rules out a candidate, never the task | `harness-adapters` dispatch reference (`references/common/dispatch.md` "Resolution") | same file | carried | 45dd50a5 |

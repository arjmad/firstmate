PR: #98

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Fleet sync prunes a gone-upstream branch only when its commits are proven landed on origin/<default> (ancestor or squash-merge tree proof), keeping and naming every other one | `bin/fm-fleet-sync.sh` (`branch_landed_on`, `prune_gone_branches`), `tests/fm-fleet-sync.test.sh` | same files | carried | 45dd50a5 |

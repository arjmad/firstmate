PR: #94

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A home-summary refresh killed past its deadline leaves no temporary files: the parent names them and removes them; contributions snapshot validates each saved record with one `jq` instead of three | `bin/fm-home-summary-refresh.sh` (`home_summary_scratch`), `bin/fm-contributions.sh` (`read_saved`), `tests/fm-home-summary-refresh.test.sh` | same files | carried | 45dd50a5 |

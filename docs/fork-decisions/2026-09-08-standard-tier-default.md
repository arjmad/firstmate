PR: #10, #57

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Standard tier by default, quota at every dispatch intake, quota read from the pinned Claude account | `bin/fm-dispatch-resolve.sh`, `bin/fm-quota-snapshot.sh`, `bin/fm-spawn.sh`, `docs/examples/crew-dispatch.json` (the bounded-work Codex rules) | those plus `bin/fm-worker-account-lib.sh` (`fm_worker_account_resolve`), `AGENTS.md`, `.agents/skills/quota-array-dispatch`, `harness-adapters` dispatch reference | carried | 9ac0288e |

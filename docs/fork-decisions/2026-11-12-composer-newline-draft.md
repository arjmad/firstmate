PR: #245

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A titled Claude composer whose draft holds only newlines reads empty and takes a doorbell: the sandwich accepts blank rows at the end of the draft, still refusing a non-blank row after a blank one | `bin/fm-composer-lib.sh`, `tests/fm-composer-lib.test.sh`, `tests/fm-backend-herdr.test.sh`, `tests/fm-herdr-submit-confirm-live-e2e.test.sh`, `tests/captures/claude-2.1.319-newline-draft/`, `docs/verification/runtime-backends.md` | `bin/fm-composer-lib.sh`, the same tests | conflicted | 9ac0288e |

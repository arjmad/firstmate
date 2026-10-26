PR: #119

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A direct-PR ship on GitHub reports `done: PR <url> checks green` only once every check at its pushed HEAD passed, with the `fleet-gate` trap named, and the ship done gate refuses that mode's GitHub done without it, retro 2026-10-26 candidate 1 that Arjun picked in the helm ("Build it") | `bin/fm-dod-lib.sh` (`fm_dod_checks_green_block`), `tests/fm-dod-lib.test.sh` | `bin/fm-dod-lib.sh` (`fm_dod_block` direct-PR, `fm_dod_accept_ship_done`, header), `bin/fm-pr-check.sh` (`DONE_LINE`), `.agents/skills/ship-landing/SKILL.md` | carried | 45dd50a5 |

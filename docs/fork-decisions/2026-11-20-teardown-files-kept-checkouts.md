2026-11-20: Arjun approved deep-audit item a1-10 at his helm walk of the 2026-11-19 audit, which found 21 scratch checkouts teardown had kept in 15 finished tasks' `data/` folders, about 780 MB, with no record surfacing them.
Decision: when teardown's scratch prune keeps a checkout, teardown files one routine noticed row, `noticed-kept-checkout-<task>`, naming every kept checkout and its reason, so firstmate proves each landed or recorded abandoned once and holds only the rest for the captain as one ask-first discard list.
A repeat teardown of the same id matches that row, and a failure to file prints a warning without failing the teardown.
No upstream proposal: the noticed queue is this fork's own patch.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Teardown files a kept scratch checkout as one routine noticed row | `bin/fm-teardown.sh` (header, scratch prune, kept-checkout filing), `tests/fm-teardown.test.sh` (`test_teardown_deletes_task_data_scratch`, `test_scout_teardown_prints_what_it_noticed`) | same files | carried | 427056c4 |
| The noticed queue names teardown as a filer and how to settle the row | `bin/fm-noticed.sh` (header), `.agents/skills/noticed-queue/SKILL.md` (Filing), `docs/configuration.md` (data scratch rule) | `docs/configuration.md` | carried | 427056c4 |

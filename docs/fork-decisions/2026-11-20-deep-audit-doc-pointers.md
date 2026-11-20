2026-11-20: Arjun approved deep-audit item a1-25 at his helm walk of the 2026-11-19 audit, and the main firstmate routed it to the Fafnir secondmate.
Decision: four pointers that sent agents to the wrong place now name the real owner, and the subagent guard drops its `bin/fm-scout.sh` branch, because no Firstmate release ever shipped that script (`git log --all -- bin/fm-scout.sh` is empty here and upstream), so its test had to fake the file.
The precedence pointer names `AGENTS.md` "Captain instruction precedence", the tangle pointer names `docs/architecture.md` "Worktrees, not branches in your checkout", the cd-guard line says a Claude helm's shell returns to the home after each command (`docs/cd-guard.md` "Claude maintained working directory"), and the fork-decisions entry point names the `kunchenguid` remote.
No upstream proposal: the scout branch is harmless upstream, and the pointers are fork prose.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The subagent guard names only the brief-then-spawn route, with no `bin/fm-scout.sh` branch | `bin/fm-subagent-pretool-check.sh` (`ROUTE`), `docs/subagent-guard.md` (deny message), `tests/fm-subagent-pretool-check.test.sh` (`test_deny_message_defers_to_intake_classification`) | same files | carried | 427056c4 |
| Doc pointers name their real owners | `AGENTS.md` (section 2 cd guard line), `.agents/skills/bootstrap-diagnostics/SKILL.md` (`TANGLE`), `docs/task-lifecycle.md` (merge authority), `docs/fork-decisions.md` (first records) | `AGENTS.md`, `.agents/skills/bootstrap-diagnostics/SKILL.md` | carried | 427056c4 |

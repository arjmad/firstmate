2026-11-19: Arjun approved trimming the retired delivery branches and the repeated authority text from `AGENTS.md`, gated on a replay test first ("Idea 2: approve with the replay test first").
Decision: `AGENTS.md` no longer describes the no-mistakes and local-only delivery paths, since every registered project ships direct-PR and every registry fallback resolves to direct-PR (2026-11-16 record); the helm still resolves merge authority and `yolo` per task, because the registry holds a project without `+yolo`.
Merge authority is stated once in section 7, captain-instruction override once in the precedence section, and hard rule 2 points at section 7; no merge-authority rule changed.
Section 7 keeps its one-line reminder that destructive, irreversible, or security-sensitive changes retain their own authority requirements: a helm decision replay of a security-sensitive ship asked the captain with it and merged under `yolo` without it.
`validation-supervision` no longer loads at ship start, because nothing starts a no-mistakes run; it still loads for an active run and before any ask-user finding.
The scripts keep their no-mistakes and local-only support, so a later sync conflicts only in prose.
No upstream proposal: upstream still ships the pipeline as its default delivery path.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| AGENTS.md drops the no-mistakes and local-only delivery branches, tells the helm every ship passes `--mode direct-PR`, and states merge authority and override once | `AGENTS.md` (precedence section, hard rules 1 and 2, section 1 shared-material shipping, section 6, section 7) | `AGENTS.md` | carried | 9ac0288e |
| validation-supervision drops its ship-start trigger | `.agents/skills/validation-supervision/SKILL.md` (description, first line), `.agents/skills/agent-skill-trigger-index/SKILL.md`, `docs/task-lifecycle.md` (Validate) | same files | carried | 9ac0288e |

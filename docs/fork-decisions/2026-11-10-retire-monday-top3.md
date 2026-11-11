2026-11-10: Arjun answered the subtraction-pass board card "Retire the Monday top 3 ideas step" with "Change the rule as proposed".
Decision: the separate Monday step that ranked new ideas and showed him the top 3 is retired; the Monday sweep checks each idea filed that week against the idea bar, and one that passes shows as one line in the `triage-weekly` row.
This changes the [2026-10-27 noticed queue](2026-10-27-noticed-queue.md) and the [2026-11-08 noticed funnel](2026-11-08-noticed-funnel.md); the [2026-10-31 idea bar](2026-10-31-idea-bar.md) itself is unchanged.
Why: the step showed him no idea in 30 days, and its record of shown ids, `state/noticed/picked`, was never written.
No upstream proposal: the noticed queue is this fork's own patch.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `fm-noticed.sh top3` and its `state/noticed/picked` record are removed, so no unseen row is labelled `top idea`; the skill's Monday sweep returns each passing idea filed that week as one line for the triage row | `bin/fm-noticed.sh` (header, `cmd_top3` removed), `tests/fm-noticed.test.sh`, `.agents/skills/noticed-queue/SKILL.md` (Monday sweep and triage, The idea bar, Weekly exploration scout), `docs/scripts.md` | none (fork-only script and skill) | carried | c8d8fdad |

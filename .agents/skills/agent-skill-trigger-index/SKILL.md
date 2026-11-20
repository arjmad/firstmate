---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# Agent-only skill trigger index

Each skill's `description` frontmatter is its load trigger, and the harness loads every description into every session, so those descriptions are the one complete trigger index.
This skill keeps no second copy, because a copy drifts from the descriptions the moment one is edited.
To audit the index, read each description in place, for example with `grep -A4 '^description:' .agents/skills/*/SKILL.md`.
To change a trigger, edit that skill's own description, and follow `firstmate-coding-guidelines` "Trigger hygiene" for when `AGENTS.md` also names it.

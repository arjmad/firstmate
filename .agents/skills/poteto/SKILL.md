---
name: poteto
description: >-
  Dispatch a poteto-mode worker when the captain types /poteto <ask> in the firstmate helm, so the worker runs poteto's pstack playbook inside its worktree while firstmate supervises and merges as usual.
  Opt-in per task by that command only; never entered by firstmate itself and never inferred from an ask's wording.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# poteto

The captain typed `/poteto` in the helm.
The ask is everything typed after the command, delivered with this invocation as its arguments.
This command is the helm's per-task opt-in to poteto's method: the worker runs Lauren Tan's pstack playbook for the ask, and nothing else about intake, supervision, landing, or merge authority changes.

The method lives in the captain's user-level Claude Code skill at `~/.claude/skills/poteto-mode/SKILL.md`, written for his own interactive sessions.
A project skill cannot take that command over: when a personal and a project skill share a name, Claude Code runs the personal one (its skills reference says so, and it held on Claude Code 2.1.287), so `/poteto-mode` typed in the helm starts the mode in the helm itself.
Do not follow it there; answer that the helm command is `/poteto`.

## Procedure

1. When the ask is empty, ask the captain one concise question for it and stop; never dispatch an inferred ask.
2. Run ordinary intake under `docs/task-lifecycle.md`: resolve the project, the deliverable (an investigation ask is a scout, while a bug fix, feature, perf, or refactor ask is a ship), the delivery mode, the `yolo` posture, and the branch prefix, exactly as for any other task.
   The method never changes the deliverable, the mode, or merge authority.
   When the ask routes to a secondmate, send the method flag and the spawn flags below with the routed request, so that home scaffolds and spawns the same way.
3. File the backlog item under section 10 with `method=poteto-mode` in its note.
4. Scaffold with the method flag: `bin/fm-brief.sh <id> <project> --mode <mode> --method poteto-mode` for a ship, or `bin/fm-brief.sh <id> <project> --scout --method poteto-mode` for a scout, plus whatever `--branch-prefix`, `--forge`, or `--herdr-lab` the task needs.
   The scaffold renders the method contract itself under `## Firstmate spec`, and it refuses when the entry skill is missing on this host; report that refusal to the captain rather than writing the method by hand.
5. Fill `## Captain's intent` with the ask verbatim under section 11, and `## Firstmate spec` with only the task-specific build instructions the ask requires; do not restate the method, its guards, or its panel seats there.
   Add the `firstmate-coding-guidelines` load line when the project is firstmate itself.
6. Spawn through `bin/fm-spawn.sh` with the usual `--mode` and `--yolo` plus this command's standing profile: `--harness claude --model claude-fable-5-1 --effort xhigh`.
   Those explicit flags are the captain's per-task override under the dispatch reference (decided 2026-10-02: a poteto-mode worker always runs Fable 5.1 at xhigh effort), so pass them on every `/poteto` spawn without consulting the dispatch profiles, and never add `--fast on`.
   A relaunch keeps the recorded flags.
7. Supervise, land, and merge exactly as for any other task under sections 7 to 9: the worker never merges, and the same merge authority applies.
   After promoting a `/poteto` scout, steer the worker once through `bin/fm-send.sh` that the `### Method: poteto-mode` subsection of its brief stays current for the ship half, because promotion treats the scout-time spec as context.
8. Reply under section 9 that the task is dispatched poteto's way, with its id; the done report, the PR URL, and the merge ask follow the ordinary path.

## Boundaries

- Firstmate never enters the mode, never reads the entry's playbooks or leaves, and never runs a panel seat; the method belongs to the worker.
- The method applies only to the task the captain opted in with this command; never carry it to a follow-up or another task.
- The command grants no standing authority: no `yolo` change, no merge authority, no fast tier.

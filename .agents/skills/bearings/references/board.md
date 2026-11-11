# Bearings Lavish board

The `bearings` skill loads this reference before it composes, answers, or refreshes the interactive fleet board.

## Composing the board

`/bearings lavish` adds one deliverable beside the unchanged chat digest: the interactive fleet board, a Lavish page in the fleet-html house style that puts everything waiting on the captain first and lets him answer each item directly instead of replying in chat.
`bin/fm-bearings-board.sh` owns every board mechanic - the stable board path, fm-bearings-board.v1 payload validation, template injection, live Lavish session verification and ended-session reopening, the any-origin answer binding, and listener registration - so the per-invocation work is composing the payload and running its `build`.

The board is inbox first: everything waiting on the captain on top, then a compact fleet strip.
Compose it from the same snapshot command run as `bin/fm-bearings-snapshot.sh --json --all-decisions --all-queued --fields board` (one gather, the board opt-ins added), with the same ranking judgment as the chat digest, plus these board rules.
`bin/fm-bearings-board.sh`'s header owns every field and refusal; these rules own what goes where.

Placement, from structured fields only (never from reason or body prose):
A row is the captain's when it is held for him or its recorded owner is `arjun` and no unfinished work blocks it: `board.queued` marks those `wait: captain`, and a fleet-owned row never enters his inbox or Later, whatever its kind.

- **Blocking a worker** (`inbox[]`, group `blocking`, key = the task id): every `in_flight` row whose `waits_on` is `captain`, the worker's structured `[on=captain]` status tag; `since` is that row's `since`.
- **Groups** (`inbox[]`, group `batch`): one item per `board.groups` entry, a group of his calls sharing one `Batch:` tag (`bin/fm-backlog-row-lib.sh` owns the tags); `batch` = its tag, `class` = its `group`, key = `batch.` plus the tag with `:` written as `.`, and `members` = each id with its full title and, from its `choices`, its `recommended`.
  A member never shows alone: it gets no card, due item, or Later row of its own, and one answer on the group works all of them.
  A group whose `back` is set was moved as a whole: it waits in Later as one `dated` row instead (`id` its key, the group's title, `back` its date).
  A board group's actions are Accept all recommended (`batch-recommended`) and a Move (`batch-defer`); a place list's are Done all (`batch-answer`), Tick each (`batch-pick`), and Move list (`batch-defer` with one date input).
- **Decisions** (`captains_call[]`): every other live captain call with no `hold_until`, quick calls (group `quick`) first by due date, then the calls that take his own hands, plus each PR ready to merge and each needed credential.
- **Due** (`inbox[]`, group `due`, key = the held task id, `due` = its `hold_until`): every `board.queued` row whose `wait` is `captain` and whose `hold_until` falls within the next 7 days, or has passed (the board shows those as Overdue).
- **Later** (`later[]`): every other `wait: captain` row - group `dated` with `back` = its later `hold_until`, group `held` for a held row with no date (aged, blocked, or waiting outside), and group `unheld` for a row he owns that is not held (Arjun's 2026-10-25 call).
- **Underway** (`underway[]`): every other `in_flight` row.
- **Queued** (`charted[]`): every `board.queued` row whose `wait` is not `captain`, with its full `title`, `wait`, `wait_date` (its `hold_until` for a date wait), and `dispatchable` = its `ready`.
- **Landed** (`landed[]`): the snapshot's landed rows.
- **Weekly prune** (`prune`): only when `board.prune.due` is true, one card proposing to drop the fleet rows nobody has touched for `age_days` or more; copy its `slot`, `more`, and each candidate's `id`, full `title`, `repo`, and `touched`, and write a short `title` and a one-line `ask`.
  `bin/fm-backlog-prune-lib.sh` owns which rows qualify and `bin/fm-backlog-prune.sh` owns the weekly slot; never add, drop, or reorder a candidate, because `build` records exactly that list as the offer the answer names.

Card and item copy, written by you per run:

- No task id, branch name, harness label, or cut-off text appears anywhere the captain reads; ids travel only as keys.
  List rows take the full title from `board.queued` or `board.titles`, never the truncated default projection.
- An inbox item has a short noun-phrase `title`, a one-line `ask` saying what he does, and two or three `actions` written for that item, the expected one first.
  Each action's `hint` says in one sentence what the fleet does on that tap, and never promises more than firstmate's authority allows: an `effect` that spends money, sends from an account firstmate does not already send from, or cannot be undone still goes through the normal authority rules when it arrives, so its hint says it prepares or asks rather than does.
  Pick the `effect` that names the route the answer takes (the header's closed set): `resume-worker` for a blocking item's actions, `close` when the answer settles a due item, `hold-until` to bring it back on a date, `remind-at` to bring it back at a time of day, `dispatch` with a one-line `brief` to start fleet work, `draft` to prepare something for his review, `send-mail` naming the account and recipient in the hint, and `record` to write values he types.
  Give an action `inputs` (value boxes) when it needs his number, date, time, or words, and name them in its `reads`; set the item's `close: "release"` when closing should free held work rather than finish it.
- A decision card carries a short noun-phrase title, one-line `about` and `decide` context rows, and two to four options specific to that decision, each with a hint saying what it does, one named in `recommend_value` (the board opens with it already chosen and offers Take all recommendations across cards), and `allow_freeform: true`.
  When the snapshot's board row carries `choices`, those are the card's options: each recorded label is an option's `label` with a slug of it as its `value`, the `recommend_value` is the value of the option whose label is the recorded `recommended`, and a recorded `ask` is the `decide` row; the intake records a pick by its label as that choice.
  An option that puts the call off is a deferral, not an answer: give it `until`, the YYYY-MM-DD it comes back, so the pick re-holds the call to that date instead of closing it; `build` refuses a `later` option without one.
  Never compose a generic Done-only card; `build` refuses a decision card with fewer than two distinct authored options, no `recommend_value` naming one, or no `allow_freeform`, and names what it lacks.
  Every decision card also carries `case_against`, one plain line of at most 300 characters giving the strongest reason to refuse its recommendation, and you never write it yourself: it comes from a fresh reviewer, one subagent with no context but each new card's title, about, decide, options, and recommendation (a fresh headless session with no conversation: on Claude, `claude -p` run from an empty temporary directory outside any firstmate home, so neither this home's instructions nor its session-start hook load, because the primary's subagent guard denies the Agent tool; on another harness, a fresh session of it the same way), asked for that one line per card in a single call.
  A card already on the board keeps its line: copy its `case_against` from `bin/fm-bearings-board.sh published` while the same key carries the same `about`, `decide`, options, and `recommend_value`, so a heartbeat refresh neither re-asks the reviewer nor changes the board; `build` refuses a decision card without the line.
  Card `type` (decision, merge, credential) is your composing judgment; set `close: "release"` on a card whose task is a captain-gated WORK item.
- An Atlas idea is a captain hold whose task id starts `atlas-`; `bin/fm-atlas.sh` files them from an `/atlas` build, and its header owns their record and the keep test.
  Compose each as a decision card titled with the idea, with `about` its estimate and evidence and `decide` "Start this?" (both from the hold reason), options `do-it` (recommended; its hint says firstmate files the brief as fleet work) and `drop`, `allow_freeform: true`, its `case_against` as above, and, when `bin/fm-atlas.sh latest` names a board, `link` {url, label "Atlas board"} to it.
- Compose exactly one card or item per captain-held task id, consolidating several questions on one task into it; keys never repeat across `captains_call` and `inbox`.
- Never author a `reconcile` option or action; `build` gives every decision card the standard reconcile choice and reserves the value.
- Before carding a hold, check that its subject has not already landed and omit it when it has: put a hold's one PR in `pr_url` and a published version in `subject`, and `build` drops a card whose task, PR, or subject appears among the landed rows or whose task is no longer an open captain call.
- An Underway row copies `in_flight.name` (full, from `board.titles`) into `name`, says its state in plain words in `doing` ("in code review", "checks rerunning", "building"; never a harness label such as "harness busy"), and carries `progress` {done, total, step} from the worker's steps in `bin/fm-progress.sh --json`, with `step` its current step in plain words, when that projection has steps.
- A Landed row carries `outcome`, a short result sentence ("Gemini on for Nova", "Keymap live on Heimdall") the board shows instead of the title, plus `pr_url` when there is one, else `artifact` for a report.
- A Queued row's optional `kind: "warning"` marks an action-free fleet-integrity notice - the `(main-inventory)` and `(return-catchup)` gates, an unavailable secondmate home, an inventory-mismatch repair notice - which the board shows under Needs repair and never counts as queued work; `charted_more` and `charted_warning_more` count omitted queued and warning rows separately.
- Every item, card, and row carries an explicit `repo` from the snapshot and task records; null or an empty string is only the deliberate genuinely-no-repo marker.

Run `build` once after composing the payload.
Its serve-first sequence publishes the board, establishes and verifies its Lavish session with `lavish-axi`, reopens an ended session when necessary, and only then binds the answer source and proves a live polling listener; use the session URL it prints in the chat digest, which `bin/fm-lavish-url.sh` has already put in its phone-openable https form; pass any other Lavish session URL through that script before giving it to the captain.
Never bind or arm the board before its session is listed open.
Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll, and both the build and the watcher's ordinary reconcile repair a missing listener, so no conversational turn ever blocks on the board.
Every full build counts as a round, so reconcile retires the board's listener only after 14 days with neither a full build nor an answer, and the next build arms it again.

## Handling a board wake

A board answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake. Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-bearings-board.sh path)"`, regardless of which answer kinds the result contains; then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Read the result with `bin/fm-procevent-lavish.sh read`: every board answer prints a BOARD ANSWER block with its question, pick, effect, values, note, and the route it took.
Answers that close or defer a captain hold need no routing from you: the runner feeds the board's binding into `bin/fm-captain-hold.sh`'s one keyed-answer intake, which closes or releases each picked decision card and each due item whose action is `close`, and re-holds `--until` the date (`deferred:`) for `hold-until` or a dated card option, never closing it; reconcile any `skipped:` key or `refused:` undated later yourself with a direct `answer` or `defer`.
Route every other answer yourself, by its effect, under the normal authority rules:

- `resume-worker`: steer the blocked worker with the action, its values, and the note through `bin/fm-send.sh`, resolving its `[on=captain]` key.
- `remind-at`: the backlog holds dates only, so for a due item run `bin/fm-captain-hold.sh defer <id> --until <its date> --decision-file <file>` and bring it back to the captain at that time; for a worker, steer it to wait until then.
- A group answer (group `batch`) names its tag on the `batch:` line, and you always route it, under the same attended rule as a single answer: `batch-answer` runs `bin/fm-captain-hold.sh answer-batch <batch> --decision-file <file>` (`--release` when the item declares `close: release`), `batch-recommended` runs it with `--recommended`, `batch-defer` runs `defer-batch <batch> --until <until> --decision-file <file>`, and `batch-pick` runs `answer <id> --decision-file <file>` for each id in `values.picked`.
  Echo every member line it prints in chat, and reconcile any `left:` or `failed:` member yourself.
- `prune` (the weekly prune card): run `bin/fm-backlog-prune.sh apply <question> <pick>`, adding `values.picked` for `drop-picked`; the tap is the captain's word for exactly those closes, so ask nothing more, and echo every `dropped:` and `skipped:` line in chat.
  A note-only prune answer drops nothing.
- An `atlas-` card answer, after the intake closed it: run `bin/fm-atlas.sh pick <id> <pick>`, and file the brief its `dispatch:` line prints as a fleet backlog task in that repo through the normal lifecycle.
  The do-it tap is the captain's word to start that work; anything it would spend, send, or delete still asks under the normal authority rules.
- `dispatch`: start the work its `brief` names through the normal lifecycle; `draft` prepares something for his review and never sends, files, or pays; `send-mail` sends only from an account firstmate already sends from, otherwise drafts and asks; `record` writes its values through the owning skill.
- Once that effect is in motion on a due item, record his pick with `bin/fm-captain-hold.sh answer <id> --decision-file <file>` (`--release` when the item declares `close: release`), so the item leaves his inbox.
- A note-only answer (no pick, route `captain instruction`) is his own words about that item: read them and act on them as a fresh captain instruction, and never close, release, or re-hold the item on the strength of a note unless the words say so.
A current structured Reconcile selection closes nothing: the versioned board context carries its exact selected option separately from any typed note, and the adapter routes that selection only into a durable re-check request while preserving the note as provenance.
A choice without the versioned context, including the pre-versioned question/answer shape, feeds neither intake and remains announced for deliberate handling.
Verify the call's latest state, then retire the request through `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` when it turns out to be moot, or `reconcile note <id> --note-file <path>` when it is genuinely still open.
Both outcomes refuse without that pending board-created request, and `bin/fm-captain-hold.sh reconcile list` names every request still outstanding.
A remote-secondmate card whose task is absent from the main backlog remains on the board unchanged, but its reconcile request is refused in the main home until the separately tracked owner-aware routing follow-up can query and mutate the authoritative secondmate home; handle the announced capture without claiming that a request or reconciliation succeeded.
`captain-hold-lifecycle` owns why a reconcile may never be recorded as the captain's answer.
Route the non-decision keys yourself:

- `merge.<task-id>` is the captain's explicit merge order; follow the merge ruling below.
- `dispatch.charted` carries comma-separated task ids the captain picked to start now; verify each id against the current backlog - still queued, blocker and time gate actually clear - then dispatch through the normal lifecycle, and report any id that no longer qualifies instead of forcing it.

After handling, rebuild the board from a fresh snapshot so acted-on items leave the inbox, and echo every action taken in chat so the board and chat never diverge silently.

## Refreshing on a heartbeat

On a heartbeat review in a home whose board exists (`bin/fm-bearings-board.sh path` names a file), compose the payload again from a fresh snapshot and run `build --if-changed`: it republishes only when the composed board differs from the last one, so an unchanged fleet never reloads a board the captain may be typing on.

## The merge-click ruling (captain-decided)

A board "Merge now" answer IS the captain's explicit merge word for that one exact PR; ask no second confirmation.
The safeguards are mandatory, not optional: resolve the PR from the task's own `state/<task-id>.meta` `pr=` record, never from board bytes; re-verify at wake time that the PR is still open and CI-green; refuse and report a red or changed PR rather than merging it; record the exact `merge` answer through `bin/fm-captain-hold.sh answer <task-id> --decision-file <file> --release` before invoking the merge; proceed only when that release succeeds; merge only through `bin/fm-pr-merge.sh`; and echo every merge in chat with the full PR URL.
Only the exact answer value `merge` authorizes a merge; an answer carrying a freeform note is the captain's instruction text to read and act on with judgment, never an auto-merge.

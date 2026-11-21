2026-11-21: Arjun chose agent-output pick D5 for firstmate task folders at his helm, in his words "Back up text, sweep media at 30 days".
Decision: a torn-down task's text is kept forever and goes into the nightly off-site backup, a separate `~/nix` change; its non-text files are deleted 30 days after teardown unless an open backlog row links the folder.
The map behind it found Heimdall's `data/` at 8.30 GB in 3,098 task folders with no retention rule and no off-site copy, 7.8 GB of it in finished tasks and 4.12 GB of that images.
For homes that opt in, this supersedes the [2026-10-26 media retention record](2026-10-26-task-media-retention.md)'s clause that still images and PDFs move to Drive before any are deleted; the media part it describes is unchanged.
The rule has no finals exemption, because D5 names none: a deliverable is filed to Drive or a repository within the 30 days.
Teardown already writes two records of its time, the `data/<task>/status.log` copy under `config/status-archive` and the closing date on the task's done backlog row, so no new record was added.
Teardown used to prune those status logs after 30 days; the [status-log keep-forever patch](2026-11-21-status-log-keep-forever.md) keeps them now, but for a task torn down earlier the done row may be the only record left.
It extends the existing media prune rather than adding a second sweep, so the torn-down test, the backlog read, and the checkout and secondmate skips keep one owner, and it rides that prune's locked session-start run.
No upstream proposal yet: upstream has no data retention of its own to extend.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Opt-in non-text retention: remove images, video, audio, PDFs, databases, archives, disk images, and data or log text over 1 MiB from tasks whose teardown record (status archive or done-row closing date) is N days old (30 by default), skipping folders an open backlog row links; `--nontext` is a dry run, `--apply` removes, and the bootstrap applies it only under `config/data-nontext-retention-days` | `bin/fm-data-media-prune.sh` (header, `unquote_ids`, `nontext_off`, `closed_dates`, `archive_closed_dates`, `nontext_task`, `status_archived`, `nontext_consider`), `tests/fm-data-media-prune.test.sh`, `docs/configuration.md` (Task non-text retention, Data size trigger), `docs/scripts.md` | `bin/fm-bootstrap.sh` (header and locked sweep comments) | carried | 427056c4 |

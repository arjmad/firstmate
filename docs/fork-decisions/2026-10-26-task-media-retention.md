2026-10-26: Arjun approved in the helm deleting the `data/ad-studio-quality-floor` renders and clip copies and "a retention rule", after Heimdall's Data volume reached 97% and Nova's ad builds and OCR check crashed for lack of space.
Decision: firstmate removes its own torn-down tasks' video, audio, and disk images under `data/<task>/` at the locked session start, opt-in per home through `config/data-media-retention-days`, and keeps reports, finals, git checkouts, and live tasks; nothing outside this home's `data/` is touched by it.
Still images, PDFs, and exports are left to Arjun's 2026-10-21 helm ruling (backlog row `fm-data-retention`): a task closed more than 60 days moves them to the Ecomills Drive in approved batches, and nothing is deleted before it lands there.
Firstmate chose this split so the rule honors both rulings.
In a home that opts in to non-text retention, Arjun's [2026-11-21 ruling](2026-11-21-task-text-kept-media-swept.md) supersedes that Drive clause: still images and PDFs are deleted 30 days after teardown, with no Drive copy.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Opt-in retention that removes the video, audio, and disk images of tasks torn down and quiet for N days (no live record, no open backlog row, a clock started at first sight) from `data/<task>/`, with a `--dry-run` listing, run as a locked bootstrap sweep | `bin/fm-data-media-prune.sh`, `tests/fm-data-media-prune.test.sh` | `bin/fm-bootstrap.sh` (locked sweep list, header), `bin/fm-session-start.sh` (header), `bin/fm-test-run.sh` (session-bootstrap family, changed map, serial hint), `docs/configuration.md`, `docs/scripts.md` | carried | 427056c4 |

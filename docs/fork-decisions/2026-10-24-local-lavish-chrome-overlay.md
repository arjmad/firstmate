PR: #106

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Local Lavish chrome overlay: a collapse toggle and drag-resize for the desktop Conversation panel (tracking kunchenguid/lavish-axi #455 and #429) and the fleet-html C1 navy colours for Lavish's own chrome, applied by bootstrap's locked pass and `install lavish-axi`, skipped fail-closed when upstream's chrome moves | `bin/fm-lavish-patch.mjs`, `bin/lavish-patch/chrome.css`, `bin/lavish-patch/chrome-client.js`, `tests/fm-lavish-patch.test.sh` | `bin/fm-bootstrap.sh` (`lavish_chrome_patch`, the `install` loop, the header), `bin/fm-session-start.sh` (header sweep count), `bin/fm-test-run.sh`, `tests/lib.sh` (`fm_fake_lavish_package`, `FM_LAVISH_PATCH=0` for every other suite), `docs/scripts.md`, `bootstrap-diagnostics` and `agent-skill-trigger-index` skills | palette superseded by #108 | 45dd50a5 |

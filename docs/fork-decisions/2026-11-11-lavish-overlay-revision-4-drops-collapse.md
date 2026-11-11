2026-11-11: lavish-axi 0.1.94 shipped its own Conversation panel collapse (the `sidebarToggle` of upstream PR #455), so on the fleet's 0.1.96 install the overlay stepped aside whole and every board opened without the house colours, the bearings receipts, or full screen for board videos.
Decision (Arjun's intent, routed through the firstmate task that fixed it): the overlay drops only the part Lavish now ships and keeps the rest, so a board shows exactly one panel collapse, Lavish's own.
This changes the [2026-10-24 overlay decision](2026-10-24-lavish-chrome-overlay.md), which dropped the whole patch once upstream shipped either control, and retires the collapse toggle of the [2026-10-24 overlay patch](2026-10-24-local-lavish-chrome-overlay.md).
Checked part by part against lavish-axi 0.1.96: its chrome colours are unchanged since 0.1.92 apart from the new toggle, it has no panel resize (upstream PR #429 is not shipped), its Conversation panel still shows a bearings answer with its raw context data, and its board iframe still carries no fullscreen grant, so those four parts stay.
The overlay now needs Lavish's own collapse and skips fail-closed on a Lavish from before 0.1.94, because it no longer brings one.
It still steps aside whole once upstream ships its own resize handle (`panelResizer`), until that part is dropped the same way.
No upstream proposal.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The Lavish chrome overlay (revision 4) no longer adds a Conversation panel collapse toggle: it restyles Lavish's own `sidebarToggle` in the house colours, keeps the drag-resize handle, the house colours, the bearings receipts and the iframe fullscreen grant, requires Lavish's own collapse as an anchor, and steps aside only for an upstream resize handle | `bin/lavish-patch/chrome-client.js`, `bin/lavish-patch/chrome.css`, `bin/fm-lavish-patch.mjs` (`REVISION`, `ANCHORS`, `UPSTREAM_RESIZE`, header), `tests/fm-lavish-patch.test.sh` | `tests/lib.sh` (`fm_fake_lavish_package` template and stylesheet), `docs/scripts.md`, `bootstrap-diagnostics` skill | carried | c8d8fdad |

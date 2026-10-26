PR: #108

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The Dracula theme replaces C1's navy as the house style, Arjun's call in the helm on 2026-10-24: the bearings board re-inlines fleet-html `house.css` v2 (arjmad/skills f619a4b, PR 229) verbatim with its board rules unchanged, and the Lavish chrome overlay maps Lavish's tokens onto the same Dracula primitives; this updates #104's and #106's palette | `.agents/skills/bearings/assets/board-template.html` (the first `<style>` block and its source comment), `bin/lavish-patch/chrome.css` (the house primitives and the token map) | same files | carried | 45dd50a5 |

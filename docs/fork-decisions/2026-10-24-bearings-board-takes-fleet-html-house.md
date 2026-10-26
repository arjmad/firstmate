PR: #104

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The bearings board takes the fleet-html house style Arjun chose in the helm on 2026-10-24 (C1 airy, navy dark only): the fleet-html skill's `house.css` is inlined verbatim, board rules read only its semantic tokens, the paper texture and Chango poster styling are gone, decision cards use a fieldset with a legend and a labelled note, and #103's phone fixes are kept; this supersedes #103's note that colors and the light-only look stay upstream's | `.agents/skills/bearings/assets/board-template.html` (both `<style>` blocks, page markup, the card, option, note, stat, and row elements the renderer builds) | same file | palette superseded by #108 | 45dd50a5 |

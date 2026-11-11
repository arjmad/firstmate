2026-11-10: Arjun reported that Sapna never heard firstmate had fixed her home DNS block, because firstmate answered Nova's plain `[nova->arjun]` inbox note with `fm-inbox.sh reply` and nothing reads a reply on a note with no request id.
Decision: `fm-inbox.sh reply` still records such a reply, and adds one line saying its sender has no handle to read it back, so firstmate answers through the sender's own lane in that turn instead of remembering a learning.
The agent side of the same fix lives in the skills repository's `fleet-handoff`: an agent's ask goes through its `file` lane, whose request id lets the agent's wake deliver firstmate's reply.
No upstream proposal: the line is small enough to carry until a sync.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `reply` adds a line when the note carries no request id | `bin/fm-inbox.sh` (`cmd_reply`, header), `tests/fm-inbox.test.sh` (reply reader case) | `bin/fm-inbox.sh` (`cmd_reply`), `tests/fm-inbox.test.sh` | carried | c8d8fdad |

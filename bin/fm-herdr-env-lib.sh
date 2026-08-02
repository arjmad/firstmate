#!/usr/bin/env bash
# Run Herdr clients without leaking Claude's child-session marker into a Herdr
# host that the client may auto-start. A host inherits its starter's environment
# and passes it to every pane; CLAUDE_CODE_CHILD_SESSION disables transcript
# saving in Claude sessions launched under those panes.
#
# Keep this scrub narrow. Other CLAUDE_CODE_* variables have no demonstrated
# host-level harm and may be intentional launch configuration.

fm_herdr_scrubbed_exec() {  # <herdr-command> [arguments...]
  env -u CLAUDE_CODE_CHILD_SESSION "$@"
}

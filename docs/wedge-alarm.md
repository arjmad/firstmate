# Away-mode injection wedge alarm - active alert channels

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS` (the pane is genuinely busy or wedged, or its Enter is swallowed), `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.

## Why an active channel beyond the status-line flash

Before this change the only ACTIVE signal `inject_wedge_alarm` sent was a tmux `display-message` status-line flash, guarded by `if [ "$backend" = tmux ]`.
That flash is a client-side OSD with no cross-backend equivalent, so on every non-tmux supervisor backend it was skipped entirely.
On 2026-07-10 a `claude`-on-`herdr` primary wedged past max-defer overnight: the tmux flash was skipped, and only the passive `state/.subsuper-inject-wedged` marker was written.
Nothing surfaces that marker until the next fleet action, so 20 escalations sat buffered for roughly 8.5 hours with no active alert.
The classifier-side half of that incident shipped separately (PR #429); this is the alarm-channel half.

`inject_wedge_alarm` now also calls `wedge_alarm_notify`, a configurable active alert that does not depend on any pane or its backend status-line.
The durable marker and the tmux flash are unchanged; the active alert is added alongside them.

## Configuration and mechanics

[`configuration.md`](configuration.md#away-mode-wedge-alarm-channels-configwedge-alarm) is the single owner of the file, environment, directive, default, and fallback schema.
`bin/fm-supervise-daemon.sh`'s header owns exact parser, invocation, timeout, ordering, and failure mechanics.
The alarm remains rate-limited to at most once per max-defer window after a genuine wedge.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable starting config.

## Test safety: no test posts a real notification

Every notifier channel (`osascript`, `herdr`, and `command:`) routes through a single seam, `FM_WEDGE_ALARM_EXEC`: when it is set, the daemon hands the fixed channel category and summary to that command instead of the real notifier (`wedge_alarm_emit` in `bin/fm-supervise-daemon.sh`).
This makes it structurally impossible for a test to post a real desktop notification, and impossible for a future test author to forget to stub:

- The daemon is only ever sourced (not executed) by tests - production `bin/fm-afk-start.sh` execs it.
  Whenever the daemon is sourced, its library-mode guard defaults `FM_WEDGE_ALARM_EXEC` to `discard`, which fires nothing.
  A real daemon a test later spawns inherits that default through the environment.
- `tests/wake-helpers.sh` upgrades the default to an on-disk recorder that logs `<channel>\t<summary>` to `$FM_WEDGE_ALARM_LOG`, so the daemon and wake suites can assert channel selection without any real notifier.
- Production leaves `FM_WEDGE_ALARM_EXEC` unset, so the real channels fire.

Because of this seam, the automated tests verify channel selection and summary propagation only.
The real `osascript`/`herdr` invocation form is verified once by the single bounded manual run below, never from a suite.

## Verification (macOS, darwin)

Recorded 2026-07-10T12:41-0700 on macOS 26.5.2 (build 25F84), `osascript` at `/usr/bin/osascript`, `herdr` 0.7.3.
This is the single bounded manual verification (two invocations, one per OS channel), labelled "FIRSTMATE TEST - IGNORE" so the banners are unmistakably harmless.
These are the only verification commands that fire real notifications, and they are never run inside a test suite.

### osascript channel (the exact argv-safe form the daemon runs)

```
$ /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
    -e 'end run' "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)"
$ echo $?
0
```

Exit 0; a Notification Center banner titled "FIRSTMATE TEST - IGNORE" was posted with the label as its body.
In production the title is "firstmate: away-mode escalations WEDGED" and the body is the `<age>s undelivered - see <marker>` summary.

### herdr channel

```
$ herdr notification show "FIRSTMATE TEST - IGNORE" \
    --body "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)" --sound request
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
$ echo $?
0
```

Exit 0; herdr reported `"shown":true`.
The daemon redirects this stdout to `/dev/null` and treats a zero exit as success.

### command channel dispatch (summary on $1 and stdin)

The `command:` channel runs `sh -c "<cmd>" fm-wedge-alarm "<summary>"` with the summary also piped on stdin.
`test_wedge_alarm_command_channel_receives_summary` deliberately unsets the seam for a safe file-writing command to verify this dispatch contract without a notification.

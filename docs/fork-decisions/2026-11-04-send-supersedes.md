PR: #172

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `fm-send.sh --supersedes <corr-id>` records that a marked secondmate request replaces an earlier one, so the superseded request is never reposted once its replacement is answered; the send refuses a malformed, unknown, other-task, or resolved id | `bin/fm-send.sh` (`--supersedes`), `bin/fm-pending-reply-lib.sh` (`fm_pending_reply_create`, `fm_pending_reply_supersedable`, `_fm_pending_reply_answered_superseder`, `_fm_pending_reply_settle_superseded_locked`, `_fm_pending_reply_has_delivery_evidence`), `tests/fm-pending-reply.test.sh`, `tests/fm-send-remote-delivery.test.sh` (`test_remote_supersedes_records_relation`) | `bin/fm-send.sh`, `bin/fm-pending-reply-lib.sh`, `tests/fm-pending-reply.test.sh`, `tests/fm-send-remote-delivery.test.sh` | conflicted | c8d8fdad |

2026-11-09: The main firstmate's operations audit 1109, run on Arjun's request to "audit our ecosystem, how firstmate runs, make sure everything is optimal", ranked the wake-queue lock race as a routine firstmate fix.
Decision: the lock library creates its lock link with `ln -sn`, and the state residue sweep retires a dead lock owner directory whose only extra entries are stray owner links.
Why: a burst of session starts left 196 owner directories in the main home's `state/`, each holding a link an acquirer dropped there by following the winner's lock link, so the hourly sweep warned about all of them, which added 24 KB to each startup digest and flooded the triage log.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The lock link is created with `ln -sn`, so a contender no longer follows an existing lock link into the winner's owner directory | `bin/fm-wake-lib.sh` (`fm_lock_try_create`), `tests/fm-watcher-lock.test.sh` (`test_lock_churn_leaves_no_stray_owner_link`) | `bin/fm-wake-lib.sh` (`fm_lock_try_create`), `tests/fm-watcher-lock.test.sh` | carried | 45dd50a5 |
| The residue sweep removes stray owner links, named after a sibling owner of the same lock and pointing at it, before it retires a dead owner directory | `bin/fm-state-residue-sweep.sh` (`is_stray_owner_link`, `owner_holds_only_lock_files`, `sweep_lock_owners`), `tests/fm-state-residue-sweep.test.sh` (`test_stray_owner_links_retired_and_live_kept`) | none (fork-owned residue sweep) | carried | 45dd50a5 |

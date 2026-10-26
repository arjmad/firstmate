2026-10-22: Arjun asked in the helm to finish the no-decision fixes of the 2026-10-22 fleet optimization review (arjmad/claude PR 47), which found CI running twice per merge on hosted runners: the pull request run, then a push run on `main` (25 jobs, about 24 minutes, 43% cancelled).
Decision: this fork sets upstream's repository variable `FM_CI_SKIP_PUSH=1` on `arjmad/firstmate`, so the push run's jobs skip and only the pull request run validates a change; `bin/fm-pr-merge.sh` reads checks at the PR head, so nothing consumes the push run.
It is repository configuration with no tracked edit and no fork-patch record; deleting the variable restores the push run.
No upstream proposal.

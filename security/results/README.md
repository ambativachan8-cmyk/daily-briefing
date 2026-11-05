# Recorded proof results

Recorded on the real VM on 2026-11-05, from a clean clone. The candidate fixtures ran in the real sandbox. GitHub was a stub.

| File | Commit | Result |
|---|---|---|
| `adversarial-baseline.log`, `.json` | `75efbb3`, attacking the audited `e2a83ce` | 17 of 17 attacks landed, as they must for the fixtures to mean anything |
| `adversarial-fixed.log`, `.json` | `75efbb3` | 21 of 21 as expected: 19 attacks blocked, 2 controls passed (an honest PR and the normal team routes) |
| `deploy-baseline.log` | `75efbb3`, attacking the audited deploy script | Reproduced: the serving tree moved to the bad commit, and the retry did nothing |
| `deploy-fixed.log` | `75efbb3` | 0 failed: failure with the old release serving, retry, rollback, automatic restore |
| `agent-boundary.log` | `75efbb3` | 0 failed. Attempts really ran as the `agent` user on the real host. Run without `--token`, because the agent token does not exist yet. |
| `fresh-setup.first-run.log` | `75efbb3` | **1 failed**: the check itself had no user bus, so `systemctl --user daemon-reload` failed. See below. |
| `fresh-setup.log` | `8d04045` | 0 failed, after fixing that check. Only that check was re-run. |
| `judge-tool-check-*.txt` | `d079ccd`'s runtime configuration | Real model runs: the reviewer has only `todo_list`; the tester-judge's catalog is empty. These are the models' reports of tool results, and predate the extra `exec.security=deny` on the tester-judge. |

**The fresh-setup failure.** It was reproduced and diagnosed. The script had already written the hold and service and no timer,
and the same script returns 0 with a user bus. `8d04045` adds a `systemctl` stub to that check and changes nothing else.

`git diff 75efbb3 8d04045 -- scripts` is empty, so the control-plane scripts under test are the same in both commits.
Run names replace absolute paths in these files. No file holds a value from the real secrets file (checked on the VM before copying).

**Re-run on 2026-11-05.** `agent_boundary.sh`, with positive controls added so a broken probe cannot look like a denial, was re-run
on the real host: [28 proven, 0 failed](../../docs/evidence/agent-boundary-rerun.log). The other proofs were not re-run. Their
scripts are unchanged, and they should run on a disposable host. **One soft result:** the `evil_requirements` baseline shows that pip
was reached with no refusal, not that the hostile directive took effect, and on the audited commit that check cannot fail.

## Not proven here

- No real agent ticket has gone through the new workflow, and `verify_pr.sh` has not run against a real open GitHub PR.
  The first needs the agent token, and each run needs the owner's approval.
- The agent token's inability to set statuses or bypass branch protection is untested, because that token does not exist yet.
  `init_secrets.sh verify` and `install_dispatch_timer.sh --enable` enforce the status check.
- The changed setup has not run on a fresh EC2 instance. See [DELIVERY.md](../../DELIVERY.md), section 7.

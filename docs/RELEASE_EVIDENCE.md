# Release evidence

What is known about this submission, how it is known, and what is not known. Written after a release review on
2026-11-05 and 06 UTC of `main` at `25b77d5`, then corrected after a retest of `cdb49e1`, which is PR #25, an operator PR that
merged with neither agent gate. These corrections are PR #26: documentation and evidence only, also operator work, also merged with neither gate.

**Who checked what.** A fresh reviewer got only the brief and the public links, with instructions to trust no claim:
[its report](evidence/independent-review-2026-11-05.md). It scored the submission 70/100 before these corrections, and that
score has not been reissued. The operator (Claude Code, the same tool that built the gates) then reproduced its findings and
ran the checks below. So "verified" here means checked directly, outside the agents' own claims. It does not mean
checked by a third party: the operator launched both reviewers on its own machine, where the owner's `gh` login was active.

**Retest.** A second fresh reviewer stalled with no result. A third, time-boxed, completed: [its report](evidence/retest-2026-11-06.md).
It reproduced the product-code diff, 61 passing tests, all token tables, all 25 mutation verdicts and the GitHub counts. It also found
overstatements in the first version of this file and of DELIVERY.md, listed at the end.

## Verified, not taken from an agent's claim

| Claim | How it was checked | Result |
|---|---|---|
| Product code is agent-authored | `git log --format='%an' -- app tests templates requirements.txt \| sort \| uniq -c` | Backend 10, UI 12, Tester 1, human 0. Author names are unsigned. |
| The test suite passes from a clean clone | Fresh venv, `python -m pytest -q`, repeated at `cdb49e1` in a throwaway clone on 2026-11-06 | 61 passed |
| The evaluator journey works on the submitted code | Fresh clone on a local port, 2026-11-06, with `curl` for every step below and one browser click that reached the refusal | First run: 12 new, first-run badge, 12 links. Run Now: 200, a row with 0 new. Second press: 429 with a message. `/ingest` shares the limit. `fail-next`: a ✗ row with its error. Next run: ✓. `GET /run-now` shows raw JSON (405), as filed in [#22](https://github.com/ambativachan8-cmyk/daily-briefing/issues/22) |
| Live deployment state, 2026-11-06 | Read-only, public `curl` and SSH. Run Now was not pressed on live, because a 0-new run removes the links from the public page ([#21](https://github.com/ambativachan8-cmyk/daily-briefing/issues/21)) | Public page and fallback URL return 200. TLS certificate valid to 2027-02-01. 25 runs stored, 1 failed. Service enabled with `Restart=always`, lingering on, Caddy enabled. No restart from 20:32:42 UTC on 2026-11-05 until the mistake described below. `tests/` is absent from the live release. A reboot itself was not tested |
| The core works under faults | [harness/fault.py](evidence/harness/fault.py), [results](evidence/fault-injection-results.txt) | 16 checks passed, 0 failed: first run, 0-new run, rate limit, 30 parallel runs with no duplicate items, failed run and recovery, malformed feed, escaping, and recovery from a crash state. That state is simulated: the server is killed and a `running` row is then inserted by hand |
| The live rate limit resists a spoofed client address | `X-Forwarded-For` sent through Caddy, then the server log read | Log shows the real address, not the spoofed one. Read over SSH, so an outsider cannot repeat it this way |
| The tests catch broken behaviour | [harness/mutate.py](evidence/harness/mutate.py), [results](evidence/mutation-results.txt) | 25 broken versions: 16 caught, 1 hung the suite, **8 not caught** ([#23](https://github.com/ambativachan8-cmyk/daily-briefing/issues/23)) |
| The agent account is really fenced off | [`agent_boundary.sh`](../security/agent_boundary.sh) on the real host, with positive controls added: [log](evidence/agent-boundary-rerun.log) | 28 proven, 0 failed. The controls catch a total failure of the probes, not a single wrong path or command, because a denial passes on any non-zero exit |
| The dispatcher is off | Read on the host | Timer masked, hold file present, agent account has no GitHub token. Read over SSH |
| `terraform init` works on Linux | Real Linux host, the committed lock and then the new one: [log](evidence/terraform-lock-linux.log) | Failed before (exit 1), passes after (exit 0) |
| Newly staged releases leave out `tests/` | Staged a release in a temp root on its own port: [log](evidence/staged-release-no-tests.log) | Ready, with no `tests/` |
| The token totals add up | The review summed every table. [The raw log](evidence/runs.jsonl) is now published | All tables total 33,905,951 |
| The agents' GitHub App cannot get past the gates | Live probes on throwaway branches with `main`'s rules: [results](evidence/app-boundary-probes-2026-11-06.txt) | Refused: publishing a gate, adding a workflow, pushing or merging past protection, changing settings, approving its own PR, and merging code changed after an approval. A control with dismissal off did merge it. Allowed, as builders need: branches, commits, PRs, comments, labels. A failed token refresh leaves the agent logged out and the run not started |
| Every cited commit and link exists | Each one resolved through the GitHub API | 28 commits and 25 links resolve |
| No secrets in git | The review scanned 1,322 blobs on all refs. The operator checked `runs.jsonl` and the refreshed configs | None found |

## Reported by the runtimes or agents, not independently checked

- **Token counts.** They are what Hermes and OpenClaw reported. OpenClaw reports zero for NVIDIA, so about 7.5M is an estimate.
- **The agents' comments and statuses.** All of them sit on one GitHub account, and before PR #20 any agent shell could have
  forged them. The trail cross-checks (the review matched label events to the second, and each agent commit to a logged run of
  that agent), but that is consistency, not proof.

## Simulated

- **The 19 blocked attacks and 2 controls in [security/results/](../security/results/).** They ran in the real sandbox with a
  stubbed GitHub, recorded by the operator at `75efbb3`. They were not re-run in this review, because they should run on a
  disposable host and that needs an AWS login. The scripts have not changed apart from the positive controls in
  `agent_boundary.sh` (`git diff 75efbb3 -- security/adversarial.py scripts/gate_lib.sh scripts/verify_pr.sh`).
- **One soft attack result.** The `evil_requirements` baseline shows that pip was reached with no refusal, not that the hostile
  directive took effect. That check on the audited commit cannot fail.

## Untested

| What | Why | What would prove it |
|---|---|---|
| A real ticket through the current workflow | [One supervised run](evidence/supervised-24-run-2026-11-06.md) reached a builder PR under the GitHub App and stopped before review and test. The dispatcher stays off until the owner approves a restart | Run tickets [#21](https://github.com/ambativachan8-cmyk/daily-briefing/issues/21) to [#24](https://github.com/ambativachan8-cmyk/daily-briefing/issues/24) |
| The current setup on a fresh VM | Earlier scripts ran end to end on 2026-11-05. The security rework has not. Needs an AWS login | `terraform apply` plus `install_all.sh` on a disposable VM |
| The team running from someone else's fork | The repo name is hard-coded. The steps are in DELIVERY section 7, and they have not been run | A fork |

## The review's findings, and what happened to each

| # | Finding | Reproduced? | Status |
|---|---|---|---|
| 1 | The agent team cannot run today, and the diagram shows a flow no ticket took | Yes, on the host | **Open: owner action.** The diagram is now labelled, and DELIVERY section 2 describes the flow that really shipped |
| 2 | The operator's role is larger than the roster shows | Yes: 56 of 56 commits, and the `#2` timeline | Disclosed in DELIVERY section 1 |
| 3 | Gates do not bind the merging account; the agents' token may merge | PR #20 confirmed. The App was then tested: it could merge once both gates were green | **Fixed for the App:** `main` requires one approving review, with stale approvals dismissed. `enforce_admins` stays off, so the owner's account is still not bound |
| 4 | Documented `terraform init` fails on Linux and macOS | Yes, on real Linux | **Fixed and retested** |
| 5 | The 6-hour schedule has not been seen firing, and DELIVERY's prediction was wrong | Yes: the service restarted at 20:32:42 UTC, so the promised 21:28 tick could not happen | **Fixed:** runs 24 and 25 fired at 02:32:42 and 08:32:42 UTC on 2026-11-06, with no restart and no POST to a run endpoint in either window. Two firings observed. See DELIVERY section 6 |
| 6 | No way to run the tests from the docs; fork and cloud-init steps missing; no reason given for AWS | Yes | Docs added. Fork steps not executed |
| 7 | "Owner comments only" does not separate the owner from the agents | Yes, by reading the code | Named as a limit in `security/README.md`. Not fixed: it needs separate GitHub identities |
| 8 | Weak tests; the suite wipes the database it finds | Yes: on a copy, 5 rows became 0 while reporting 61 passed | **Fixed in deployment and on the live release.** The suite itself: ticket [#23](https://github.com/ambativachan8-cmyk/daily-briefing/issues/23) |
| 9 | No agent-by-phase token split; wrong planning model | Yes | **Fixed:** report regenerated from the real log, and operator use marked as uncounted |
| 10 | Thin first-run wording; items vanish after Run now; raw dates; `/run-now` shows JSON | Yes, in a real browser | Tickets [#21](https://github.com/ambativachan8-cmyk/daily-briefing/issues/21) and [#22](https://github.com/ambativachan8-cmyk/daily-briefing/issues/22), for the agents |
| 10 | At 375 px the layout widens to 424 px | **No.** In a real browser at 375 px the page was 375 wide | Closed, not reproduced |
| 11 | A database error gives a 500 and no failed row | Yes: [log](evidence/db-error-repro.log) | Ticket [#24](https://github.com/ambativachan8-cmyk/daily-briefing/issues/24), for the agents |
| 11 | No security headers, public API docs, no CSRF check | Yes | Accepted: no login, no private data, and no paid model behind the public button |
| 12 | Boundary proof had no positive control; one attack check cannot fail | Yes | Control **partly fixed** and rerun: see the Verified table. Attack check disclosed above |
| 13 | Stale `openclaw.json` | Yes | **Fixed:** refreshed from the live config and scanned for secrets |

## What the retest changed

| Retest finding | Result |
|---|---|
| "14.0M is the gates doing their job" | **Withdrawn.** Recomputed: 6,192,947 tokens, 44% of repeat runs, directly follow a failed attempt. "Mostly on quota" withdrawn too: the log has no failure reason |
| Human specification understated | **Corrected:** at least three comments on #2, not one |
| Positive controls overstated | **Corrected** above and in `security/results/README.md` |
| "Staged releases cannot wipe production" overstated | **Reworded.** On the VM, checked over SSH: one release, no `tests/`, no rollback target. The new deploy line has run only in a temp root, not in a real deploy |
| Status line ignored #24 | **Corrected** |
| "External" and "independent" labels | **Corrected** for the Codex audit, which the operator ran |
| PR #25 not disclosed | **Corrected** |
| First tick not recorded | **Corrected** |
| Run Now step wrong when the feed has gained an item | **Corrected** |
| Removed "no dark-mode styling", and no as-of date | **Restored** |
| `javascript:` link not mentioned | **Disclosed** in DELIVERY section 6 |
| Lock file for `linux_arm64` and `darwin_arm64` | Not confirmed by the retest, because of its network. Generated on real Linux with those platforms requested, and only `linux_amd64` was actually run |
| Commits `21e566d`, `72c949b`, `7dba3db`, `ec74208` | Open on GitHub, but not in a clone, because PR #13 was force-pushed |
| README commands fail on Windows | They are POSIX commands. The Windows equivalent passed in the retest |
| Nemotron under 4 labels in the per-model table | Left as logged |

**A mistake on the live VM, 2026-11-06.** While checking the deployed release, the operator ran `~/deploy/current/scripts/deploy_app.sh --status` at 09:29:22 UTC. That copy, from release `e2a83ce`, predates the staged layout: it has no `--status`, and it deployed `main` to `~/app`, rewrote the service unit and restarted the service. The cause was running a script without reading that copy first. For about 81 seconds the public site served `~/app/data/briefing.db`: an older database with 21 runs, plus one new row (22 rows shown, newest "3 new"). The production database in `~/deploy/shared/data` was not touched, and its integrity check passes. The owner had not approved a deploy. The operator restored `e2a83ce` straight away with the control copy's `deploy_app.sh --activate-only`, without waiting, because visitors were seeing the wrong history. That restart added run 26 (0 new) to the real history and moved the next scheduled tick to about 15:30 UTC. The Caddyfile was rewritten with the same content. Copies of the stray database and of the backup the restore replaced are in `~/deploy/quarantine/`. `~/app` is unused and remains on the VM. The hold and the masked timer were not touched.

**One action taken on the live VM.** `tests/` was moved out of the serving release to `~/deploy/quarantine/`, so nobody can erase
the public history by running the suite there. No restart. The public page stayed up and all rows remained.

**Two false alarms from the review's own harness, recorded so that nobody repeats them.** Some early fault-injection runs
failed because of test-harness bugs, not product bugs: a future timestamp on a seeded row, and on Windows a leftover child
process and an undrained log pipe. Those runs were discarded and the published results come from the corrected harness.

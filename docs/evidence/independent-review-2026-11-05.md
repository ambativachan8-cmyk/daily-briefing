> Written by a fresh reviewer given only the brief, the public URL and the public repository, with instructions to trust no claim. Copied unedited apart from this note. Its findings were then reproduced and acted on: see [../RELEASE_EVIDENCE.md](../RELEASE_EVIDENCE.md). The reviewer ran on the same machine as the operator, as it says below.

# Blind evaluation: Daily Briefing take-home

Evaluated 2026-11-05 21:47 to 22:10 UTC against `main` at `25b77d5`. Inputs: the brief, the public URL, the public repo.

Vantage-point caveats:
- The `gh` CLI on this machine was logged in as the candidate's own account. I used read calls only, and I re-checked the branch-protection result without authentication.
- Port 22 answered from here, but this machine's address may be inside the VM's `admin_cidr`. So that result says nothing about what a stranger sees.

## Score: 70 / 100

| Area | Points | Why |
|---|---|---|
| Agent team design and orchestration | 19 / 30 | Roles are clear and send-backs are real, but a bash router and the human side did most of the steering. Gates passed bad work repeatedly, and the current gated flow has never run a real ticket. |
| Evidence the agents delivered | 20 / 25 | All product lines blame to agent authors and the ticket trail is rich and checks out. It all sits on one unsigned GitHub identity, with very prescriptive human-side fixes. |
| Models, tokens and observability | 10 / 15 | Measured and estimated are clearly separated and the totals reconcile. There is no agent-by-phase split, the operator's strong model is uncounted, and the reviewer ran mostly on flash-lite. |
| Infra as code and reproducibility | 9 / 15 | Terraform validates and no secrets are in history. The committed lock file holds only one platform's hash, the agent team cannot be rerun from a fork without edits, and the current setup has never run on a fresh VM. |
| It runs | 8 / 10 | The page, Run now, dedup, rate limit and failed row all work. The 6-hour schedule has never been seen firing, and first-run wording is thin. |
| Judgement and write-up | 4 / 5 | Unusually honest about failures, but long and top-heavy, with a few statements that do not hold. |

No "not passing" condition applies: there is a public link, a repo, and agent-authored code.

## Findings, ranked by impact

### 1. HIGH: the agent team cannot run today, and the ticket diagram shows a flow no ticket ever took

**Observed**
- `DELIVERY.md:3`: "Agent automation is paused". Line 139: "No real agent ticket has gone through the new workflow". Line 140: "The agents' narrower token does not exist yet".
- The section 2 diagram has steps such as "Owner approves the exact head over SSH" and "Hermes Reviewer judges diff and receipt, no tools". Every real review predates this. For example, the PR #18 review says "checked out locally; verify_pr.sh, pytest and all probes below were run against exactly this commit".
- `agents/hermes/reviewer/SOUL.md` now says "You have no shell and no file access".
- PR #20 (the security rework) was the last merge, at 21:25 UTC. It changed prompts and scripts across 45 files, about 22 minutes before this evaluation.

**Reproduce**
```
grep -n "No real agent ticket" DELIVERY.md
gh api repos/ambativachan8-cmyk/daily-briefing/issues/18/comments --jq '.[].body' | grep -m2 "checked out locally"
```

**Inferred**
- The brief's follow-up asks to "have it make a small change live". That needs a new token, restarting the dispatcher and a first-ever run of an untested flow.
- `agents/` prompts are not the prompts that produced the shipped code. Those live only in git history.

### 2. HIGH: the human side, not the gates, did most of the catching, and its operator is missing from the roster and token report

**Observed**, counted by tag and wording across all issue and PR comments:
```
reviewer_approved 17, reviewer_changes_requested 6, tester_pass 12, tester_fail 2,
human_reject 9, dispatcher_return 8
```
- `DELIVERY.md:311-312` concedes "The human side caught more serious defects than the reviewer did on the lite-model days".
- The human side's fix requests are close to implementation specs. `#2` comment of 23:04 UTC says:
  > `git rm -r --cached venv`
  > "in a thread, start a run whose fetch blocks on an event. From the main thread call `ingest_feed()` and assert it returns busy in under one second, with `run_id` None"
- `tests/test_regression.py::test_regression_5_lock_concurrency` follows that recipe. On PR #18 the UI agent wrote "exactly as the owner specified".
- 56 of the 56 non-merge operator commits carry `Co-Authored-By: Claude Opus 5.5`. The gate and security code they include totals about 3,000 lines.
- The roster has five agents, and the token report covers only them.
- The manager was bypassed. In the `#2` label timeline, the send-backs at 22:22, 22:52 and 23:06 UTC went straight to `role:backend` with no manager run.

**Reproduce**
```
gh api "repos/ambativachan8-cmyk/daily-briefing/issues/2/timeline?per_page=100" --jq '.[]|select(.event=="labeled")|"\(.created_at) \(.label.name)"'
git log --author=Vachan --no-merges --format='%(trailers:key=Co-authored-by,valueonly)' | sort | uniq -c
```

**Inferred**
- `[human-owner]` comments were probably drafted by Claude Code, which DELIVERY calls the "operator". I cannot prove that.
- A strong model outside the team acting as the real reviewer and fix-writer sits close to the brief's "do not paste a line-by-line plan into a weaker model". This is disclosed in part, but its scale is not visible from the roster.

### 3. HIGH: gates do not bind the account that merges, and the agents' token may be able to merge

**Observed**
```
$ curl -s https://api.github.com/repos/ambativachan8-cmyk/daily-briefing/branches/main
"enforcement_level": "non_admins", "contexts": ["agent/review","agent/test"], "app_id": null
```
- PR #20 merged with no statuses at all: `gh api repos/ambativachan8-cmyk/daily-briefing/commits/5e0b171/statuses` returns 0 entries for that head. So `agents/PROTOCOL.md:63` ("enforced by branch protection") does not hold for this account.
- 49 first-parent, non-merge commits went straight to `main`. These are the operator commits, including gate scripts and prompts. This is disclosed at `DELIVERY.md:301`, though the disclosure says only that the fix "is a PR", not that it skipped both gates.
- All statuses, comments, PRs and merges show one login (`ambativachan8-cmyk`). There are 0 GitHub `assigned` events and 0 formal reviews; assignment is by label.
- `security/README.md:86` says "the token cannot merge or set gates". `DELIVERY.md:303` says whether it can bypass protection "must be tested". The documented scope is `Contents RW` and `Pull requests RW` (`agents/agents.env.example`).
- `pre-push` protection of `main` is a hook in the agent's own clone (`scripts/setup_agents.sh`).

**Inferred**
- By my reading of GitHub's permissions, Contents write is what a merge requires, so that token can merge a PR once the statuses are green. That removes "agents do not merge" as an enforced rule. If the owner's admin bypass extends to it, it could also merge or push without them. I could not test this.
- Before PR #20 every merge gate was forgeable, as DELIVERY admits. The trail looks like good-faith use of those gates but cannot prove it.

### 4. HIGH: the documented `terraform init` fails on Linux and macOS

**Observed**
- `infra/.terraform.lock.hcl` has one `h1` hash and no `zh` hashes. That hash matched the Windows provider package (init succeeded here on `windows_amd64`).
- The `linux_amd64` hash differs:
```
$ terraform providers lock -platform=linux_amd64
"h1:aLOQts7nCLMR0kb/jCdP56wlQQoGqhKLctKgtQjDopc="    (added)
"h1:rMbzU/i9txGvoI/hiB6EMln0NlmxM/61SrI9XBvI41Q="    (committed)
```
- I simulated the mismatch here by locking to only the Linux hash and running init on Windows:
```
Error while installing hashicorp/aws v6.71.0: the current package for
registry.terraform.io/hashicorp/aws 6.71.0 doesn't match any of the checksums
previously recorded in the dependency lock file
```

**Inferred**
- `cd infra && terraform init` as written in DELIVERY section 7 fails the same way on a Linux or macOS machine. `terraform init -upgrade` should get past it.

**Otherwise fine:** `terraform fmt -check` passes and `terraform validate` reports "Success". The configuration has IMDSv2, an encrypted root volume, SSH restricted to `admin_cidr`, and local state that is git-ignored.

### 5. HIGH: "pull on a schedule" is barely evidenced, and DELIVERY's own prediction failed

**Observed**
- `DELIVERY.md:3` says "This file states only what has been verified". Line 328 says the 6-hour setting was applied at 15:28 and "its first tick is due at 21:28 UTC".
- At 22:07 UTC there was no such row. The gaps in `/runs`:
```
17 14:21:44
18 15:21:44 gap=3600s    <- the only row provably fired by the timer
19 15:26:52 gap=307s
20 15:28:03 gap=70s
21 16:39:26 gap=4283s
22 20:32:42 gap=13995s
23 21:49:25 gap=4602s    <- my Run now
```
- The scheduler is `asyncio.sleep(interval)` in the web process and it ticks at startup (`app/scheduler.py`). Any restart adds a row and resets the phase.
- The page cannot distinguish scheduled rows from manual ones.
- Neither pytest nor `verify_pr.sh` checks a second tick. Two mutations both left 61 of 61 passing: making the scheduler stop after its first tick, and making it ignore the interval.

**Reproduce**
```
curl -s https://13-55-31-171.sslip.io/runs
```

**Inferred**
- Row 22 falls about a minute after the security commit `d079ccd` (20:31 UTC). It was probably the VM migration restarting the service. That would have moved the next tick to about 02:32 UTC, making the 21:28 statement stale when it was written. The alternative is a dead scheduler task. I cannot tell which without VM access.

### 6. MEDIUM: a stranger can rerun the product, but not the agent team, and the docs give no way to run the tests

**Observed**
- Neither README nor DELIVERY gives local test or run commands. What I ran instead, on Python 3.14 on Windows:
```
python -m venv .venv
pip install -r requirements.txt     # ok, 30 s
python -m pytest -q                 # 61 passed, 2810 warnings in 7.41s, exit 0 (twice)
```
- `git status --porcelain` stayed empty. A `data/briefing.db` is created in the checkout.
- `REPO` is hard-coded with no override in `gate_lib.sh`, `init_secrets.sh` and `ticket.sh`, and the URL in `setup_agents.sh` and `install_all.sh`. `OWNER` is derived from it.
- Nothing creates labels or branch protection: `grep -rn "protection\|label create" scripts` finds no creation step. `ticket.sh` refuses unknown labels.
- No documented step waits for cloud-init, while `init_secrets.sh install` needs `gh`, which cloud-init installs.
- `DELIVERY.md:360` says the setup as changed by the security fix has not been run on a fresh EC2 instance, and installers are unpinned. That is disclosed. The earlier fresh-VM run has no artifact I could open.
- AWS was used with no statement that Oracle was tried. The brief makes AWS plan B after a day of being blocked. `grep -ni oracle DELIVERY.md` gives one line and no reason.

**Inferred**
- A fork needs code edits, manual labels and manual protection before its first ticket can move.

### 7. MEDIUM: "owner comments only" does not separate the owner from the agents

**Observed**
- `thread_for`, `managed_tickets` and `eligible_pr` in `scripts/dispatch.sh` and `scripts/gate_lib.sh` filter on `author.login == OWNER`. PROTOCOL says all agents post under that same account.
- Reviewer and tester prompts include those comments under the heading "Comments from the owner account".
- `dispatch.sh:420` runs `git pull --ff-only` on the control-plane checkout before each run. A merged PR therefore changes code that runs as the sudo-capable `ubuntu` account. No gate treats `scripts/` specially.

**Inferred**
- This blocks outsiders, which is what the proofs test. A builder with a shell can still post `[human-owner] ...` into the reviewer's prompt, or create a "managed" ticket.
- Receipts and the human merge still sit behind this. The specific hole is not named in `security/README.md`, which mentions one account only in terms of status authorship.

### 8. MEDIUM: test suite weaknesses, some contradicting claims

**Observed**: 16 mutations in a scratch clone, run with `python -m pytest -q`. 9 were killed and 7 survived.

| Mutation | Result |
|---|---|
| Treat every item as new | killed, 11 fail |
| ID from title | killed, 8 fail |
| First-run flag always false | killed, 5 fail |
| Page lists all seen items | killed, 1 fail |
| Failed run stored as success | killed, 1 fail |
| No rate limit on `/run-now` | killed, 2 fail |
| Failed row shows a check mark | killed, 1 fail |
| Scheduler never started | killed, 1 fail |
| No DB overlap guard in ingest | killed, 1 fail |
| Rate limit 60 s changed to 1 s | **survived** |
| `/ingest` not rate limited | **survived** |
| `/ingest` overlap check removed | **survived** |
| Scheduler stops after first tick | **survived** |
| Scheduler ignores interval | **survived** |
| Date removed from briefing meta | **survived** |
| First-run wording dropped from the briefing heading | **survived** |

- `verify_pr.sh` covers the rate-limit items, but only on the VM. Its "dated briefing" regex scans the whole page, so history rows satisfy it.
- `tests/test_feed.py:335` `test_ingest_lock_prevents_overlapping` never holds a lock. Its comment says "This test is tricky". The owner ordered this "no-op" replaced on `#2`. A new test was added, but the no-op is still there.
- `test_scheduler_error_resiliency` has no assertion.
- The scheduler tests patch the interval to `"0.1"`, which `int()` rejects, so they exercise the default path, not a short interval.
- `test_a6` line 243 asserts `"✓" in html` as proof of recovery, but run 1 already put a ✓ on the page.
- `test_ingest_endpoint` and `test_run_now_endpoint` accept `status in ("success","failed")`.
- `tests/test_main.py` and `test_scheduler.py` run `DELETE FROM runs` on the real `data/briefing.db`.

**Inferred**
- `deploy_app.sh` links each release's `data` to the shared production database and ships `tests/` and pytest. So `cd ~/deploy/current && .venv/bin/pytest` would wipe live history. The README sends operators to that directory. DELIVERY flags the write as a test debt but says "the live app runs from its own checkout", which understates this.

### 9. MEDIUM: token report lacks the required split, and one role's model does not match its log

**Observed**: the totals do reconcile.
- Agent/model table, by-agent table, phase table and the 176 every-run rows all sum to 33,905,951.
- 291 turns × 25,707 tokens ≈ 7.5M, which matches the labelled NVIDIA estimate. 78% retries is correct.

Gaps:
- There is no agent × phase table, though the brief asks for tokens per agent split by phase. The data supports one. I derived this from the every-run rows:
```
failed attempts 12,479,743 (backend 7.60M, ui 3.74M, tester 1.14M); repeat OK runs 14,048,186
backend coding 2.28M; ui coding 0.12M; reviewer first 3.08M, repeats 5.44M
```
- "Retries" lumps quota-failed attempts with legitimate re-reviews of new heads, so the 78% headline mixes waste with normal rework.
- The operator's Claude Code and Codex usage is uncounted anywhere.
- The retries row does not add up: fresh + cache-read exceeds total by 228,847. Trace 3 shows why: a Hermes run with `input_tokens:219621` and `total_tokens:0`. Reviewer `nemotron...:free` shows input 1,738,134 and total 1,526,720.
- `DELIVERY.md:25` says "planning ran on `gemini-3.5-flash`". The log says `20261102T212136Z | manager | plan | gemini-3-flash-preview`.
- The reviewer, the brief's "stronger model" role, ran 20 of its 32 attempts on flash-lite. This is disclosed.
- Raw `runs.jsonl` is not in the repo.
- 90 of 176 attempts ended in `error`.

### 10. MEDIUM to LOW: product wording and UX

**Observed**
- First-run wording is a green badge reading "first run" in history row 1. "Everything is new" appears nowhere: `grep -rn "nothing to compare\|everything is new" templates app` returns nothing. The brief says "say so on the page".
- After one Run now, the top of the page reads `Date: 2026-11-05T21:49:25.191569+00:00 | 0 new` and "No new items in this run." The only visible item (Item 10) is gone. No page link reaches earlier briefings; only JSON at `/runs/22` does. Any passer-by blanks the briefing until the next 6-hour boundary. The brief's example does show 0 after Run now, but it has no route back to the items.
- Dates are raw ISO with microseconds, and the page never says what the source is, how often it runs or that it is synthetic. This is partly disclosed as "warts".
- Item links go to a 404: `curl -o /dev/null -w '%{http_code}' https://example.com/item-10` returns 404. Items are "Item 10 title" and "Description for item 10".
- `GET /run-now` returns `{"detail":"Method Not Allowed"}`. After a click the browser sits on that URL, so entering it again shows raw JSON.
- `get_runs(limit=100)` caps the page at 100 rows, against the brief's "history of every run". At about one row per minute per IP that is reachable, and it would push the ✗ and first-run rows off the page.
- At 375 px the layout widens to 424 px, because the unbroken timestamp column forces the width.

**Fine**
- No JavaScript at all (0 scripts), and the page works without it.
- The form POST returned 200 and added one row with 0 new.
- An immediate retry returned 429 with "Rate limited. Try again in 58.9s."
- History, ✓ and ✗ render correctly. Failed run 10 shows its error, and run 11 recovers.
- Counts are consistent: new items sum to 10 across 23 runs and the feed holds 10.
- HTTP redirects to HTTPS. The fallback `http://13.55.31.171` works.

### 11. LOW: application security

**Observed**
- Rate limit spoofing failed, which is good. A POST with spoofed `X-Forwarded-For`, `X-Real-IP`, `Forwarded`, `True-Client-IP` and `CF-Connecting-IP`, and the raw-IP route, all returned 429 inside the window.
- Limits are per-IP and in-memory: they reset on restart and the dict grows without bound. There is no paid model behind them.
- Unauthenticated `POST /ingest` duplicates Run now. A POST carrying `Origin: https://evil.example` succeeded, so there is no CSRF check. Low impact given the brief wants a public button.
- `/docs`, `/redoc` and `/openapi.json` are public.
- Response headers have no HSTS, CSP, X-Frame-Options or nosniff. They reveal `Server: uvicorn` and `Via: 1.1 Caddy`.
- Open ports from here among those checked: 22, 80, 443 only. 8000, 18789, 9119 and the other common ports timed out.
- Local run with a hostile `FEED_ITEMS_JSON`: HTML is escaped (`&lt;script&gt;`), but `href="javascript:alert(1)"` is not filtered. This is unreachable today because the feed is synthetic, but it would matter on a real feed.
- `acquire_lock` yields a second time in its `except`. A `sqlite3.OperationalError` from inside the run gives `RuntimeError: generator didn't stop after throw()`, a 500 on `/run-now`, and no failed row. I reproduced this locally with a patched `create_run`.

**Fine**
- Secret scan of all 1,322 blobs on all refs including PR heads found no API keys, tokens or private keys. The only hits were 2 example or test CIDRs (`infra/terraform.tfvars.example`, `scripts/verify_pr.sh`) and generic strings in the once-committed `venv/`.
- SQL is parameterized.
- `/.env`, `/.git/config` and `/data/briefing.db` return 404.
- Seven merge commits carry the candidate's personal Gmail address as author, which is a minor privacy note.

### 12. LOW: security proof harness has soft spots

**Observed**
- `DELIVERY.md:134`: attacks "cannot pass by being unable to detect the bug". But the `evil_requirements` baseline predicate is `passes or "pytest exit code" in output` (`security/adversarial.py:604`). The audited script prints that line unconditionally (`git show e2a83ce:scripts/verify_pr.sh`, line 39), and all four baseline runs show `rc=1`. So that "ATTACK LANDED" cannot fail.
- `security/agent_boundary.sh` `denied()` prints `PROVEN` on any non-zero exit, with no positive control. A broken `sudo -u agent`, or a wrong path, would also print PROVEN. 18 of the 25 lines in `agent-boundary.log` are of this kind.
- Judge tool checks are the models' own reports, which the results README states.
- The proof scripts are unchanged since the recorded run (`git diff 75efbb3 HEAD -- security/adversarial.py scripts security/stubs` is empty), and the JSON files match the logs. That part is sound. I could not re-run them.

### 13. LOW: handover drift

**Observed**
- `agents/openclaw/openclaw.json` has 0 mentions of `tester-judge` and 9 `/home/ubuntu` paths. It was last updated at `e2a83ce`, so it predates the accounts it should show.
- `agents/README.md`'s roster "records the first model plan" and disagrees with DELIVERY's roster.
- There is no `skills` material under `agents/`, and no screen recording (optional).
- `ec74208`, `21e566d` and `72c949b` are cited but absent from a clone, because PR #13 was force-pushed 3 times. They do still resolve via the GitHub API. All other cited SHAs resolve, and all relative links in the docs resolve.

## What confused me as a first-time reader

- **Product:** about a minute. It is one page with a button. I still could not tell the schedule or the source from the page.
- **Agent system:** about 15 to 20 minutes of reading (my estimate), and I needed the git history to separate what happened from what is now designed.
- DELIVERY opens with paused automation and a "Codex" audit before it explains the team. The ticket flow it diagrams is not the one the trail shows, and section 4 alone is about 155 lines.
- "Human", "owner", "operator", "human-side" and "Claude Code" are used loosely. I could not tell who actually found what.
- Three names exist for the router (`dispatcher`, `control-plane`, the manager's "assign"). The manager is called orchestrator, yet "no model decides who works next".
- There are two rosters with different models.

## What impressed me, after verification

- **The ticket trail is real and cross-checks.**
  - TRACES label events for `#2` match GitHub's timeline to the second.
  - The statuses on `ea55954` and `72c949b` match what TRACES quotes.
  - All 28 agent commits fall within minutes of a logged same-agent run start (0 to 918 s). Several are only 4 to 7 s after an attempt start, which is tight but not impossible.
- **Product code authorship is clean.** `git blame` on `app/`, `templates/`, `tests/` and `requirements.txt` gives Backend 1,569, UI 399, Tester 327, and 0 human lines. All merge commits are clean (`git diff-tree --cc` shows no hand-resolved changes). Author names are self-declared and unsigned, as finding 3 notes.
- **Gates sent work back.**
  - The reviewer rejected a stub on PR #13.
  - The reviewer caught the JavaScript intercept on PR #18 that curl could not.
  - The tester failed a broken requirements pin.
  - The manager escalated `#3` at its retry limit.
- **The core works.** Stable-ID dedup is plain code and killed its mutations, and the live data is consistent.
- **Honesty about failure is rare and mostly accurate.** The numbers I checked in DELIVERY reconcile, and the failures it lists appear in the trail.
- **Deterministic checks replaced model promises.** The `verify_pr.sh` design and its receipts are good, though not yet exercised on a real PR.

## What I could not test, and why

- VM state, the hold file, Hermes and OpenClaw installs, the dispatcher and agent token: rules forbid SSH.
- Whether the runtimes really produced the work: no raw logs or recording are published, so this rests on configs, the run table and timing.
- `security/adversarial.py`, `deploy_proof.sh` and `agent_boundary.sh`: they need the VM, systemd sandbox and sudo.
- `terraform apply`: no cloud credentials. Linux `terraform init` was simulated, not run on Linux.
- Whether the agent token can merge or bypass protection: the token does not exist.
- The schedule's next tick, likely about 02:32 UTC, is after this report. I stopped at 22:08 UTC with no new row since my own run.
- SSH reachability for a stranger: my network may be allowlisted.

I used 1 successful Run now, plus 1 rate-limited `/run-now` and 3 rate-limited `/ingest` calls, on the live site.

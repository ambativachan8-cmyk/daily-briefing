# Delivery report — Daily Briefing (Confer take-home #3)

> **Status: in progress.** This file states only what has been verified; open items are
> marked _open_. Last updated 2026-11-03.

| | |
|---|---|
| Live URL | _open — deploys automatically when the first app PR merges_ (`https://13-55-31-171.sslip.io`, fallback `http://13.55.31.171`) |
| Repository | https://github.com/ambativachan8-cmyk/daily-briefing |
| Ticket trail | [Issues](https://github.com/ambativachan8-cmyk/daily-briefing/issues?q=is%3Aissue) · [Pull requests](https://github.com/ambativachan8-cmyk/daily-briefing/pulls?q=is%3Apr) |
| Token report | `docs/TOKEN_REPORT.md` (_open — generated from the run log at the end_) |
| Spend | $0 on model APIs; VM on AWS Free-plan credits (~$3.10/day) |

## 1. Who did what

**Agents (all product code, tickets, reviews, tests).** Five agents on two frameworks, each
with its own workspace, its own git clone and git author, and a pre-push hook that blocks
`main`:

| Agent | Framework | Role |
|---|---|---|
| Hermes Manager | Hermes Agent v0.22.5 (profile `manager`) | Turns the brief into tickets, releases dependencies, re-queues send-backs |
| OpenClaw Backend Builder | OpenClaw 2026.10.9 (agent `backend`) | Ingestion, storage, dedup, scheduler |
| OpenClaw UI Builder | OpenClaw 2026.10.9 (agent `ui`) | Public page, history, Run-now |
| Hermes Reviewer | Hermes Agent v0.22.5 (profile `reviewer`) | Code review; sets the required `agent/review` status |
| OpenClaw Tester | OpenClaw 2026.10.9 (agent `tester`) | Independent tests; sets the required `agent/test` status; owns the acceptance suite |

Models per agent and how each was verified: [agents/README.md](agents/README.md).

**Human side (Vachan, with Claude Code as operator).** Terraform VM, runtime installs, agent
identities, role prompts and ticket protocol, model wiring, the deterministic dispatcher,
deployment, supervision, merges, and this report. No product code was written on the human
side; every file under `app/` and `tests/` comes from an agent-authored commit (check with
`git log --format='%an' -- app tests | sort | uniq -c`).

## 2. How work flows

1. `scripts/dispatch.sh next` (systemd timer, every 10 min) reads issue labels and picks
   exactly one agent: review → test → send-backs → ready work → manager triage. Routing is
   plain label matching; no model decides who works next. One agent runs at a time (`flock`).
2. Agents act only through `git` and `gh`: branches `agent/<role>/<issue>-<slug>`,
   `Refs #n` commits, PRs with `Closes #n`, label transitions via `scripts/ticket.sh`.
3. **Merge gate.** Branch protection on `main` requires commit statuses `agent/review` and
   `agent/test` = success. A human merges only after both pass.
4. Merged `main` is redeployed automatically (`scripts/deploy_app.sh --if-changed`).

Full protocol: [agents/PROTOCOL.md](agents/PROTOCOL.md).

## 3. Trail so far

Agent rows are visible on GitHub (issues, PR #8, commit statuses) and in the run log;
operator rows are commits on `main`.

| When (UTC) | Agent | Event |
|---|---|---|
| 11-02 21:21 | Hermes Manager | Planned the brief into #1–#6 and the Delivery status issue #7; released only #1 |
| 11-02 21:23–21:27 | OpenClaw Backend Builder | Branch `agent/backend/1-scaffold`, commit `4f5e3e0`, opened PR #8 (13 tests) after two Gemini quota failures and a resume on the fallback model |
| 11-02 21:28 | Hermes Reviewer | Inspected the diff, checked out and ran the tests, set `agent/review=success` |
| 11-02 21:35 | Operator (`bb328f1`) | Judged that review insufficient (one-line verdict, labels not moved, protocol slip missed); tightened the reviewer prompt and handoff tooling instead of editing labels by hand. #1 stays `in-review` for a second review |
| _open_ | | Second review, independent test, merge, remaining tickets |

## 4. Honest limitations

- **One GitHub account.** All agents share one repo-scoped token, so GitHub shows every
  comment and PR under the owner's account. Authorship is carried by per-agent git authors
  and the signature tag that starts each comment. GitHub therefore refuses formal
  "approve" reviews (self-approval); the gate is the two required commit statuses.
- **Gate strength.** `enforce_admins` is off so the human can merge; the gate is protocol +
  per-clone pre-push hooks + branch protection, not cryptographic separation.
- **Free-tier capacity.** Gemini free tier is 20 requests/day and 5/min per model per
  project; OpenRouter free is 50/day. This, not engineering time, sets the pace; the
  dispatcher pauses until the reset (08:00 UTC) instead of retrying.
- **AWS instead of the brief's first choice**: the Free-plan account is locked to
  `ap-southeast-2`; Terraform targets that region.

## 5. Reproduce

```bash
cd infra && cp terraform.tfvars.example terraform.tfvars   # set admin_cidr, key path
terraform init && terraform apply
ssh ubuntu@<ip> 'bash -s' < scripts/vm_bootstrap.sh      # OpenClaw + Hermes
# copy agents.env (see agents/agents.env.example) to ~/.secrets/agents.env on the VM
ssh ubuntu@<ip> 'git clone https://github.com/ambativachan8-cmyk/daily-briefing ~/agents/_src &&
  bash ~/agents/_src/scripts/setup_agents.sh && bash ~/agents/_src/scripts/configure_models.sh &&
  bash ~/agents/_src/scripts/install_dispatch_timer.sh'
```
Agent dashboards stay on loopback; reach them with the tunnel from `terraform output`.

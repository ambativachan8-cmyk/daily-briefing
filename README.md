# Daily Briefing

A small scheduled briefing that checks one feed, reports only what is new since the last
run, and publishes a dated briefing with a run history on a public page.

**Project overview:** [docs/showcase](docs/showcase/README.md) has the architecture, ticket flow, verified capabilities and limits at a glance.

The product code in this repository is written by a team of autonomous agents
(OpenClaw + Hermes Agent). The human engineer set up the infrastructure, the agent
runtimes and the ticket protocol, and reviews/merges. See:

- [agents/](agents/) — agent roster, prompts, sanitized configs, ticket protocol
- [docs/PRODUCT_BRIEF.md](docs/PRODUCT_BRIEF.md) — the requirement the agents work from
- [infra/](infra/) — Terraform for the single VM
- [DELIVERY.md](DELIVERY.md) — delivery report: team, ticket flow, what broke, tokens, how to reproduce. **Start here.**
- [docs/RELEASE_EVIDENCE.md](docs/RELEASE_EVIDENCE.md) — what was verified, reported by agents, simulated and untested
- [security/](security/) — the security boundary of the agent workflow, and the attack fixtures that test it
- Live: https://13-55-31-171.sslip.io

## Run it locally

Use a fresh clone: the test suite empties `data/briefing.db` in the checkout it runs in. These are Linux or macOS commands, and on Windows use `python` and `.venv/Scripts/`. The tests were run on Python 3.14; the live app runs on 3.12.

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

```bash
.venv/bin/python -m pytest -q
```

```bash
rm -f data/briefing.db && .venv/bin/uvicorn app.main:app --port 8000
```

## Operations

To make the next fetch fail on the running service for testing/operator intervention:
```bash
cd ~/deploy/current && .venv/bin/python -m app.ops fail-next
```

To see what is deployed, or to return to the previous release:
```bash
~/agents/_src/scripts/deploy_app.sh --status
```
```bash
~/agents/_src/scripts/deploy_app.sh --rollback
```


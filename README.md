# Daily Briefing

A small scheduled briefing that checks one feed, reports only what is new since the last
run, and publishes a dated briefing with a run history on a public page.

The product code in this repository is written by a team of autonomous agents
(OpenClaw + Hermes Agent). The human engineer set up the infrastructure, the agent
runtimes and the ticket protocol, and reviews/merges. See:

- [agents/](agents/) — agent roster, prompts, sanitized configs, ticket protocol
- [docs/PRODUCT_BRIEF.md](docs/PRODUCT_BRIEF.md) — the requirement the agents work from
- [infra/](infra/) — Terraform for the single VM
- [DELIVERY.md](DELIVERY.md) — delivery report: team, ticket flow, what broke, tokens, how to reproduce
- [security/](security/) — the security boundary of the agent workflow, and the attack fixtures that test it
- Live: https://13-55-31-171.sslip.io

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


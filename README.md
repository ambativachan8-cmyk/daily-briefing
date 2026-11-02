# Daily Briefing

A small scheduled briefing that checks one feed, reports only what is new since the last
run, and publishes a dated briefing with a run history on a public page.

The product code in this repository is written by a team of autonomous agents
(OpenClaw + Hermes Agent). The human engineer set up the infrastructure, the agent
runtimes and the ticket protocol, and reviews/merges. See:

- [agents/](agents/) — agent roster, prompts, sanitized configs, ticket protocol
- [docs/PRODUCT_BRIEF.md](docs/PRODUCT_BRIEF.md) — the requirement the agents work from
- [infra/](infra/) — Terraform for the single VM
- [DELIVERY.md](DELIVERY.md) — delivery report (kept current as tickets land)

Status: agent team running; first ticket in review. See DELIVERY.md.

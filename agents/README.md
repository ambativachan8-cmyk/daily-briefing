# Agent team

Sanitized configuration, prompts and skills for each agent. Secrets are never stored here;
they live in `~/.secrets/agents.env` on the VM (git-ignored, not in this repo).

| Agent | Runtime | Role | Prompt | Model (primary → fallback) |
|---|---|---|---|---|
| Hermes Manager | Hermes Agent, profile `manager` | Orchestrator | [hermes/manager/SOUL.md](hermes/manager/SOUL.md) | _set after live model verification_ |
| Hermes Reviewer | Hermes Agent, profile `reviewer` | Review + merge gate | [hermes/reviewer/SOUL.md](hermes/reviewer/SOUL.md) | _set after live model verification_ |
| OpenClaw Backend Builder | OpenClaw, agent `backend` | Builder (ingest/store/dedup/schedule) | [openclaw/backend/AGENTS.md](openclaw/backend/AGENTS.md) | _set after live model verification_ |
| OpenClaw UI Builder | OpenClaw, agent `ui` | Builder (page/history/Run-now) | [openclaw/ui/AGENTS.md](openclaw/ui/AGENTS.md) | _set after live model verification_ |
| OpenClaw Tester | OpenClaw, agent `tester` | Tester | [openclaw/tester/AGENTS.md](openclaw/tester/AGENTS.md) | _set after live model verification_ |

Ticket flow and labels: [PROTOCOL.md](PROTOCOL.md).

# Agent team

Sanitized configuration, prompts and skills for each agent. Secrets are never stored here;
they live in `~/.secrets/agents.env` on the VM (git-ignored, not in this repo).

| Agent | Runtime | Role | Prompt | Model (primary → fallbacks) |
|---|---|---|---|---|
| Hermes Manager | Hermes Agent v0.22.5, profile `manager` | Orchestrator | [hermes/manager/SOUL.md](hermes/manager/SOUL.md) | `gemini-3.5-flash` → `gemini-3-flash-preview` → `gemini-3.6-flash` → `gemini-3.5-flash-lite` → `gemini-3.1-flash-lite` → OpenRouter `nvidia/nemotron-3-ultra-550b-a55b:free` |
| Hermes Reviewer | Hermes Agent v0.22.5, profile `reviewer` | Review + merge gate | [hermes/reviewer/SOUL.md](hermes/reviewer/SOUL.md) | `gemini-3.6-flash` → `gemini-3.5-flash` → `gemini-3-flash-preview` → `gemini-3.5-flash-lite` → `gemini-3.1-flash-lite` → OpenRouter Nemotron-3-Ultra `:free` |
| OpenClaw Backend Builder | OpenClaw 2026.10.9, agent `backend` | Builder (ingest/store/dedup/schedule) | [openclaw/backend/AGENTS.md](openclaw/backend/AGENTS.md) | `google/gemini-3.5-flash` → `google/gemini-3.6-flash` → `google/gemini-3-flash-preview` → `google/gemini-3.5-flash-lite` → `google/gemini-3.1-flash-lite` → OpenRouter Nemotron-3-Ultra `:free` |
| OpenClaw UI Builder | OpenClaw 2026.10.9, agent `ui` | Builder (page/history/Run-now) | [openclaw/ui/AGENTS.md](openclaw/ui/AGENTS.md) | `google/gemini-3-flash-preview` → `google/gemini-3.5-flash` → `google/gemini-3.6-flash` → `google/gemini-3.5-flash-lite` → `google/gemini-3.1-flash-lite` → OpenRouter Nemotron-3-Ultra `:free` |
| OpenClaw Tester | OpenClaw 2026.10.9, agent `tester` | Tester | [openclaw/tester/AGENTS.md](openclaw/tester/AGENTS.md) | `google/gemini-3.6-flash` → `google/gemini-3-flash-preview` → `google/gemini-3.5-flash-lite` → `google/gemini-3.1-flash-lite` → OpenRouter Nemotron-3-Ultra `:free` |

Ticket flow and labels: [PROTOCOL.md](PROTOCOL.md). Router and runner:
[../scripts/dispatch.sh](../scripts/dispatch.sh). Model wiring:
[../scripts/configure_models.sh](../scripts/configure_models.sh).

## Model providers (all zero-cost, verified 2026-11-03)

- **Google AI Studio, free tier.** Two keys in two separate projects: one for the Hermes
  agents, one for the OpenClaw agents. A live 429 from a Pro model reports quota ids ending
  `-FreeTier`, so these keys are not billing-enabled. Free-tier limits observed:
  **5 requests/min and 20 requests/day per model per project**, plus frequent 503
  "high demand" responses on the newest models. Primaries are spread across models so
  agents do not drain the same per-model quota.
- **OpenRouter, `:free` models.** The key's spending limit is **$0** and `is_free_tier` is
  true, so it cannot incur charges; free models are capped at 50 requests/day per account.

Every model listed above answered a live request through the agent's own runtime or the
provider API before it was assigned. Gemini 3.7/3.8 Flash and Gemma 4 were tried and left
out (503/500 at the time).

## Rate-limit handling

- **Hermes** switches models mid-run on its own (`fallback_providers`), and waits out a
  rate-limit window shorter than 90 s instead of spending OpenRouter's daily requests.
- **OpenClaw** will not change model mid-turn once a tool has run (replay safety), so the
  dispatcher resumes the same session on the next model when a turn ends in a quota error,
  and records the exhausted model until the daily reset (08:00 UTC).

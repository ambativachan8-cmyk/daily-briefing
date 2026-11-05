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

All five run as the unprivileged `agent` account, not as the control plane, and the tester gives verdicts as `tester-judge`,
which has no tools ([security/README.md](../security/README.md)). The table above records the first model plan.

Ticket flow and labels: [PROTOCOL.md](PROTOCOL.md). Router and runner:
[../scripts/dispatch.sh](../scripts/dispatch.sh). Model wiring:
[../scripts/configure_models.sh](../scripts/configure_models.sh).

## Model providers (all zero-cost; first verified 2026-11-03)

- **Google AI Studio, free tier.** Two keys in two separate projects: one for the Hermes
  agents, one for the OpenClaw agents. A live 429 from a Pro model reports quota ids ending
  `-FreeTier`, so these keys are not billing-enabled. Free-tier limits observed:
  **20 requests/day per project on flash and 500/day on flash-lite**, with per-minute limits on
  top and frequent 503 "high demand" responses on the newest models. Buckets are shared
  across names: `3.5-flash` draws on `3.6-flash`, and `3.7-flash` on `3.8-flash` (read from the
  429's `quotaDimensions`, 2026-11-05). Each chain lists a bucket once.
- **OpenRouter, `:free` models.** The key's spending limit is **$0** and `is_free_tier` is
  true, so it cannot incur charges; free models are capped at 50 requests/day per account.

Gemma 4 is left out: its 16,000 input tokens/min is below one agent prompt (about 25k tokens).
Omni and 3.1 Pro have no free quota, and the 2.5 models return 404. The current chains are in
[../scripts/configure_models.sh](../scripts/configure_models.sh); the table above records the first plan.

- **NVIDIA hosted API, free, added 2026-11-05.** Native provider in both runtimes, first in every chain
  when `NVIDIA_API_KEY` is set. Tested with a 31k-token prompt and one tool: `nvidia/nemotron-3-ultra-550b-a55b`
  (3.5 s) and `z-ai/glm-5.3-flash` (10 s) called it correctly. `deepseek-v4.1-flash` took 78 s, and
  `kimi-k2.6` returned 404 on this account. No rate-limit headers are published.

## Rate-limit handling

- **Hermes** switches models mid-run on its own (`fallback_providers`), and waits out a
  rate-limit window shorter than 90 s instead of spending OpenRouter's daily requests.
- **OpenClaw** will not change model mid-turn once a tool has run (replay safety), so the
  dispatcher resumes the same session on the next model when a turn ends in a quota error,
  and records the exhausted model until the daily reset (08:00 UTC).

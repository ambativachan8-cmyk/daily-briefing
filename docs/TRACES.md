# Trace excerpts

Real lines, copied unedited except where marked `…` (shortened). Sources: the dispatcher's
per-attempt log (`~/logs/usage/runs.jsonl`, some fields dropped), `~/logs/dispatch.log`, and
GitHub's own issue events, commit statuses and comments.

## 1. A handoff: reviewer → manager → builder (ticket #2)

GitHub label events, in order:

```
2026-11-04T21:05:47Z labeled status:changes-requested      # reviewer rejects
2026-11-04T21:05:48Z labeled role:manager                  # sent to the orchestrator
2026-11-04T21:09:42Z labeled role:backend                  # manager re-queues to the builder
2026-11-04T21:09:42Z labeled status:ready
2026-11-04T21:14:24Z labeled status:in-progress            # builder picks it up
2026-11-04T21:27:20Z labeled status:in-review              # builder hands back to review
2026-11-04T21:27:20Z labeled role:reviewer
```

The same steps in the dispatcher's log:

```
{"ts":"20261104T210423Z","agent":"reviewer","issue":"2","exit":0,"model":"gemini-3-flash-preview","provider":"gemini","api_calls":12,"input_tokens":205310,"output_tokens":8213,"total_tokens":213870}
{"ts":"20261104T210645Z","agent":"manager","issue":"2","exit":0,"model":"gemini-3.6-flash","provider":"gemini","api_calls":16,"input_tokens":191529,"output_tokens":5532,"total_tokens":197426}
{"ts":"20261104T211814Z","agent":"backend","issue":"2","status":"ok","model":"openrouter/nvidia/nemotron-3-ultra-550b-a55b:free","provider":"openrouter","assistant_turns":38,"input_tokens":169265,"output_tokens":24163,"total_tokens":3481428}
```

Each agent's closing line, from `~/logs/dispatch.log`:

```
REVIEWED #2 CHANGES_REQUESTED https://github.com/ambativachan8-cmyk/daily-briefing/pull/9
TRIAGED #2 re-queued to role:backend with status:ready
DONE #2 https://github.com/ambativachan8-cmyk/daily-briefing/pull/9
```

## 2. A review rejection (PR #9, head `ea55954`)

Commit statuses on that head, newest first. The reviewer overturned an earlier approval once its
prompt required tracing each PR to the brief:

```
2026-11-04T21:05:43Z agent/review=failure Items table lacks title/link fields required for history display
2026-11-03T09:43:40Z agent/test=success All 31 tests passed successfully
2026-11-03T09:31:43Z agent/review=success All checks passed; approved for merge
```

The reviewer's comment on the PR (2026-11-04, excerpt):

```
[hermes-reviewer] Review of ea55954 — CHANGES REQUESTED
| Trace to brief | ✗ | `items` table lacks `title` and `link`; cannot display history if feed changes (Req 2, 4) |
Required changes:
1. `app/db.py:43` — The `items` table schema only stores `id` and `feed_id`. To satisfy Product Brief Req 2 …
```

The manager's re-queue on the ticket (excerpt):

```
[hermes-manager] Re-queuing to backend. The human owner found several gaps in the previous implementation that must be addressed:
… Ticket text updated to reflect these requirements. This is retry #1.
```

## 3. A failed gate run that was not allowed to count

A reviewer run on the old head died on a quota error after posting a verdict. It posted and set a
status on `ea55954`, not on the PR's head `0dfea2a`, so the merge gate stayed closed. The dispatcher
now names the exact head in every review and test prompt.

```
{"ts":"20261104T213056Z","agent":"reviewer","issue":"2","exit":2,"model":"nvidia/nemotron-3-ultra-550b-a55b:free","provider":"openrouter","api_calls":15,"input_tokens":219621,"output_tokens":1261,"total_tokens":0}
Provider said: HTTP 429: Rate limit exceeded: free-models-per-day. …
2026-11-04T21:31:54Z agent/review=success Approved by Hermes Reviewer      # on ea55954, not the PR head
```

## 4. A quota retry

A builder attempt hitting Gemini's limit and resuming in the same session on the next attempt:

```
{"ts":"20261104T222955Z","agent":"backend","issue":"2","status":"error","model":"google/gemini-3.5-flash-lite","provider":"google","assistant_turns":18,"input_tokens":61683,"output_tokens":4632,"total_tokens":279124}
⚠️ Google Generative AI API error (429): You exceeded your current quota, please check your plan and billing details. …
```

The dispatcher first treated any repeated 429 as daily exhaustion. A probe right after answered 200,
which exposed the bug: the limit hit was the 5-per-minute window. The probe log and a corrected
ledger followed:

```
gemini-3-flash-preview 429 GenerateRequestsPerDayPerProjectPerModel-FreeTier
gemini-3.5-flash-lite 200
gemini-3.1-flash-lite 200
```

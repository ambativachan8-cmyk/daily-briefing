# Product brief: Daily Briefing

Source: Confer Inc. take-home #3. This file states the requirement, not the implementation.
The Hermes Manager turns it into tickets.

## What it does

On a schedule, the app reads one source, works out which items are new since the last run,
and publishes a dated briefing on a public web page together with a history of every run.

## Required behaviour

1. **Source.** A controlled synthetic feed served by this project (a file or endpoint that
   gains a few made-up items over time). It must be possible to make the feed fail on
   purpose so failed runs can be demonstrated and tested.
2. **Store every run.** When it ran, success or failure (with error), and the items it saw.
   SQLite on the VM.
3. **What is new.** Each item has a stable ID (feed id, else a hash of its link). A run's new
   items are those whose ID was never stored before. Plain deterministic code, no model.
   The first run has nothing to compare with: everything is new, and the page says so.
4. **Public page, no login.** Top: latest briefing with its date, number of new items, and a
   short line + link per new item. Below: run history, one row per run with time,
   ✓ or ✗, and number of new items.
5. **Runs.** A scheduled run (one scheduler) and a manual "Run now" control. Run-now is
   rate-limited, and two runs never execute at the same time.
6. **Optional, only after the core works:** a one-line summary per item from a free model;
   on HTTP 402/429 or any model error, publish the plain list instead.

## Acceptance tests

| # | Scenario | Expected |
|---|---|---|
| A1 | First run on a feed with 3 items | 3 new, marked as first run |
| A2 | Second run, identical feed | 0 new |
| A3 | Same items, different order | 0 new |
| A4 | One item added | exactly 1 new |
| A5 | A previously seen item re-appears after being removed | 0 new |
| A6 | Feed fetch fails | run stored as failed (✗) with error; next good run succeeds and reports correctly |
| A7 | Load the page | latest briefing and history visible without login |
| A8 | Run now / schedule | manual run adds a history row; rate limit enforced; no overlapping runs |

## Out of scope

RAG, vector databases, Kubernetes, paid APIs, authentication, multi-user features.

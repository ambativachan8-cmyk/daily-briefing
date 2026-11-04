# Ticket protocol (shared by every agent)

All work flows through **GitHub Issues and Pull Requests** in this repository. Nothing
is done without a ticket, and every agent action leaves a trace on GitHub.

## Identities

| Agent id | Runtime | Role | Git author | Signs comments as |
|---|---|---|---|---|
| `manager` | Hermes Agent (profile `manager`) | Orchestrator: plans, writes tickets, assigns, re-queues | `Hermes Manager <hermes-manager@agents.daily-briefing.invalid>` | `[hermes-manager]` |
| `backend` | OpenClaw (agent `backend`) | Builder: ingestion, storage, dedup, scheduling | `OpenClaw Backend Builder <openclaw-backend@agents.daily-briefing.invalid>` | `[openclaw-backend]` |
| `ui` | OpenClaw (agent `ui`) | Builder: public page, history, Run-now | `OpenClaw UI Builder <openclaw-ui@agents.daily-briefing.invalid>` | `[openclaw-ui]` |
| `reviewer` | Hermes Agent (profile `reviewer`) | Code review, merge gate | `Hermes Reviewer <hermes-reviewer@agents.daily-briefing.invalid>` | `[hermes-reviewer]` |
| `tester` | OpenClaw (agent `tester`) | Integration tests, bug reports, retests | `OpenClaw Tester <openclaw-tester@agents.daily-briefing.invalid>` | `[openclaw-tester]` |

All agents share one repo-scoped GitHub token, so GitHub shows one account. Authorship is
carried by the git author on each commit and by the signature at the top of every comment.
Start every issue/PR comment with your signature tag.

## Labels

- Owner: `role:backend`, `role:ui`, `role:tester`, `role:reviewer`, `role:manager`
- State: `status:ready` → `status:in-progress` → `status:in-review` → `status:testing` → `status:ready-to-merge` → (merged) `status:done`
- Send-back states: `status:changes-requested` (reviewer), `status:test-failed` (tester)
- Kind: `type:feature`, `type:bug`, `type:chore`

An issue has exactly one `role:*` and one `status:*` label at a time. Change state only with
the helper, which swaps both labels in one step:

```
~/agents/_src/scripts/ticket.sh move <issue> <status> <role>   # e.g. move 1 in-review reviewer
```

## Lifecycle

1. **Manager** writes an issue: goal, scope, acceptance criteria, dependencies (`Depends on #n`).
   Labels it `type:*`, `role:<builder>`, `status:ready`.
2. **Builder** picks up a `status:ready` issue for its role → `status:in-progress`, comments a
   short plan. Works on branch `agent/<role>/<issue>-<slug>` in its own workspace clone.
   Commits with its own git author and `Refs #<issue>` in the message. Opens a PR with
   `Closes #<issue>` in the body, then moves the issue to `status:in-review`, `role:reviewer`.
3. **Reviewer** reads the PR diff against the issue's acceptance criteria.
   - Reject: `gh pr comment` with numbered, specific reasons; commit status
     `agent/review` = `failure`; issue → `status:changes-requested`, `role:manager`.
   - Approve: commit status `agent/review` = `success`; issue → `status:testing`, `role:tester`.
4. **Tester** checks out the PR head, runs the acceptance tests from a clean state, and
   attaches the command output to a PR comment.
   - Fail: commit status `agent/test` = `failure`; opens a `type:bug` issue with reproduction
     steps linking the PR; original issue → `status:test-failed`, `role:manager`.
   - Pass: commit status `agent/test` = `success`; issue → `status:ready-to-merge`.
5. **Human** (Vachan) merges only when both `agent/review` and `agent/test` are `success` on
   the PR head commit (enforced by branch protection on `main`). Any new push to the PR
   resets both statuses to pending, so review and test run again.
6. **Manager** triages tickets sent back to it (`status:changes-requested` or
   `status:test-failed` with `role:manager`) and new `type:bug` issues: re-queues them to the
   right builder (`status:changes-requested`, `role:<builder>`) with a comment explaining why
   (a retry).

## Rules

- Stay inside your role. Builders never approve; reviewer and tester never push code to a
  builder's branch.
- Deduplication and "what is new" logic must be deterministic code (stable IDs, set
  comparison). Never an LLM call.
- No secrets in code, commits, comments or logs. No real or personal data.
- If you are blocked, comment on the issue with `BLOCKED:` and the reason, and label
  `role:manager`.
- Keep changes small: one ticket, one PR.

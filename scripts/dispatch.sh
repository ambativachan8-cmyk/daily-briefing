#!/usr/bin/env bash
# Deterministic ticket router + agent runner (runs on the VM).
#
#   dispatch.sh next              route the next actionable ticket by its labels
#   dispatch.sh <agent> [issue]   run one agent explicitly (manager|reviewer|backend|ui|tester)
#
# Routing is plain label matching — no model decides who works next. One agent runs at a
# time (flock). Every run appends one line per attempt to ~/logs/usage/runs.jsonl and keeps
# the agent's raw output in ~/logs/runs/ for the trace.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
unset GH_TOKEN   # gh uses its own credential store (see configure_models.sh)

REPO="ambativachan8-cmyk/daily-briefing"
LOG="$HOME/logs"; mkdir -p "$LOG/usage" "$LOG/runs" "$LOG/quota"
LEDGER="$LOG/quota/exhausted.tsv"   # "<model>\t<epoch until>" for OpenClaw's Gemini key
touch "$LEDGER"

exec 9>"$LOG/dispatch.lock"
flock -n 9 || { echo "another agent run is in progress"; exit 0; }

# Open tickets as "<number> <label,label,...>", oldest first; the pinned report issue is not a ticket.
issues() { gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels \
             --jq 'sort_by(.number) | .[] | select(.title != "Delivery status")
                   | "\(.number) \([.labels[].name] | join(","))"'; }

# Depends on #n: every referenced issue must be closed before a builder may start.
deps_closed() {
  local n
  for n in $(gh issue view "$1" --repo "$REPO" --json body --jq .body | grep -oiE 'depends on #[0-9]+' | grep -oE '[0-9]+'); do
    [ "$(gh issue view "$n" --repo "$REPO" --json state --jq .state)" = "CLOSED" ] || return 1
  done
}

route() {
  local list n labels role
  list="$(issues)"
  [ -z "$list" ] && { echo "manager plan"; return; }
  # 1) review, 2) test, 3) send-backs and interrupted work to builders, 4) ready builder
  # work, 5) manager triage. The tester is also a builder for test-suite tickets (role:tester).
  while read -r n labels; do case ",$labels," in *,status:in-review,*) echo "reviewer $n"; return;; esac; done <<<"$list"
  while read -r n labels; do case ",$labels," in *,status:testing,*) echo "tester $n"; return;; esac; done <<<"$list"
  while read -r n labels; do
    case ",$labels," in *,status:changes-requested,*|*,status:in-progress,*)
      for role in backend ui tester; do case ",$labels," in *,role:$role,*) echo "$role $n"; return;; esac; done;; esac
  done <<<"$list"
  for role in backend ui tester; do
    while read -r n labels; do
      case ",$labels," in *,role:$role,*) case ",$labels," in *,status:ready,*)
        deps_closed "$n" && { echo "$role $n"; return; };; esac;; esac
    done <<<"$list"
  done
  while read -r n labels; do
    case ",$labels," in
      *,blocked,*|*,status:ready-to-merge,*) continue;;   # human decides these
      *,role:manager,*|*,status:test-failed,*) echo "manager $n"; return;;
    esac
  done <<<"$list"
  # 6) a held ticket (no status yet) whose dependencies are now merged: manager releases it
  while read -r n labels; do
    case ",$labels," in *,status:*) continue;; esac
    deps_closed "$n" && { echo "manager $n"; return; }
  done <<<"$list"
  echo "idle"
}

# The open PR whose body says "Closes #<n>" (exact number, not a substring match).
pr_for() {
  gh pr list --repo "$REPO" --state open --limit 100 --json number,body \
    --jq '[.[] | select(.body | test("(?i)(closes|fixes|resolves) #'"$1"'([^0-9]|$)")) | .number] | first // empty'
}

prompt_for() {
  local agent="$1" n="${2:-}" pr=""
  [ -n "$n" ] && pr="$(pr_for "$n")"
  case "$agent" in
    manager)
      if [ -z "$n" ]; then
        echo "There are no open tickets. Plan the project: read docs/PRODUCT_BRIEF.md and agents/PROTOCOL.md in this clone, then create the tickets on GitHub as your SOUL.md describes. To save model calls, write all gh commands into one shell script and run it once. Finish with one line: PLANNED <issue numbers>."
      else
        echo "Ticket #$n needs you. Run: gh issue view $n --repo $REPO --comments. Follow your SOUL.md: if it was sent back or is a bug, re-queue it to the right builder with a comment explaining why (or mark blocked after 3 retries); if it is held and its dependencies are merged, release it with status:ready. Then update the Delivery status issue. Finish with one line: TRIAGED #$n <action>."
      fi;;
    reviewer)
      echo "Issue #$n is in review; its PR is #${pr:-?} in $REPO. Review it exactly as your SOUL.md says: inspect the diff, run the tests yourself, post the evidence table, set the agent/review commit status on the PR head, and move the ticket with ticket.sh. Finish with one line: REVIEWED #$n APPROVED|CHANGES_REQUESTED <PR url>.";;
    backend|ui|tester-build)
      echo "Work ticket #$n. Read AGENTS.md in your workspace and daily-briefing/agents/PROTOCOL.md, then run: gh issue view $n --repo $REPO --comments. If it was sent back, address every numbered point in the latest review/test comment on the same branch and PR. Work inside ./daily-briefing. Finish with one line: DONE #$n <PR url> or BLOCKED #$n <reason>.";;
    tester)
      # status:testing = verify someone else's PR; any other state = the tester's own ticket
      if [ "$(gh issue view "$n" --repo "$REPO" --json labels --jq '[.labels[].name] | index("status:testing") != null')" != "true" ]; then
        prompt_for tester-build "$n"; return
      fi
      echo "Issue #$n passed review and is ready for testing; its PR is #${pr:-?} in $REPO. Read AGENTS.md in your workspace and daily-briefing/agents/PROTOCOL.md. Independently of the builder and reviewer: check out the PR head in ./daily-briefing, use a fresh virtualenv and a temporary database, run the full test suite and the acceptance scenarios that apply to this ticket, post the exact commands and output, set agent/test on the PR head commit, and move the ticket with ticket.sh. Finish with one line: TESTED #$n PASS|FAIL <PR url>.";;
  esac
}

log_jsonl() { jq -nc "$@" >> "$LOG/usage/runs.jsonl"; }

run_hermes() {
  local agent="$1" n="$2" msg="$3" ts out usage rc
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; out="$LOG/runs/$ts-$agent-${n:-plan}.txt"; usage="${out%.txt}.usage.json"
  set +e
  timeout 2400 hermes -p "$agent" --in "$HOME/agents/$agent/daily-briefing" --yolo \
    -t terminal,file,todo -z "$msg" --usage-file "$usage" >"$out" 2>&1
  rc=$?; set -e
  log_jsonl --arg ts "$ts" --arg a "$agent" --arg n "$n" --argjson rc "$rc" --arg out "$out" \
    --slurpfile u <(cat "$usage" 2>/dev/null || echo '{}') \
    '{ts:$ts, agent:$a, framework:"hermes", issue:$n, exit:$rc, model:$u[0].model, provider:$u[0].provider,
      api_calls:$u[0].total_including_auxiliary.api_calls, input_tokens:$u[0].input_tokens,
      output_tokens:$u[0].output_tokens, cache_read_tokens:$u[0].cache_read_tokens,
      total_tokens:$u[0].total_including_auxiliary.total_tokens, actual_cost_usd:0,
      list_price_estimate_usd:$u[0].total_including_auxiliary.estimated_cost_usd, output:$out}'
  tail -n 3 "$out"
  # A run that ended on provider limits did not complete its work: pause Hermes until reset.
  if [ "$rc" -ne 0 ] || ! jq -e '.completed == true and .failed != true' "$usage" >/dev/null 2>&1; then
    grep -qiE '429|RESOURCE_EXHAUSTED|rate.?limit|quota' "$out" && next_reset > "$LOG/quota/hermes-paused-until"
    return 1
  fi
}

# Gemini free tier resets at midnight Pacific (08:00 UTC in winter).
next_reset() {
  local t; t="$(date -u -d 'today 08:00' +%s)"
  [ "$t" -gt "$(date +%s)" ] || t="$(date -u -d 'tomorrow 08:00' +%s)"
  echo "$t"
}

# OpenClaw does not switch models mid-turn once a tool has run (replay safety), so on a
# quota error we resume the same session on the next model with remaining free quota.
run_openclaw() {
  local agent="$1" n="$2" msg="$3" key="agent:$1:issue-${2:-0}" models m ts out status text retried=""
  models="$(openclaw config get "agents.entries.$agent.model" | jq -r '.primary, .fallbacks[]')"
  for m in $models; do
    awk -v m="$m" -v now="$(date +%s)" '$1==m && $2>now {f=1} END {exit !f}' "$LEDGER" && continue
    while :; do
      ts="$(date -u +%Y%m%dT%H%M%SZ)"; out="$LOG/runs/$ts-$agent-${n:-0}.json"
      set +e
      timeout 2400 openclaw agent --agent "$agent" --session-key "$key" --model "$m" \
        --message "$msg" --json --timeout 2300 >"$out" 2>"${out%.json}.err"
      set -e
      status="$(jq -r '.status // "error"' "$out" 2>/dev/null || echo error)"
      text="$(jq -r '.result.payloads[-1].text // .summary // ""' "$out" 2>/dev/null || true)
$(cat "${out%.json}.err" 2>/dev/null)"
      log_jsonl --arg ts "$ts" --arg a "$agent" --arg n "$n" --arg m "$m" --arg s "$status" --arg out "$out" \
        --slurpfile r <(cat "$out" 2>/dev/null || echo '{}') \
        '($r[0].result.meta.agentMeta // {}) as $x | {ts:$ts, agent:$a, framework:"openclaw", issue:$n,
          status:$s, model:$m, provider:$x.provider, assistant_turns:$x.assistantTurns,
          input_tokens:$x.usage.input, output_tokens:$x.usage.output, cache_read_tokens:$x.usage.cacheRead,
          total_tokens:$x.usage.total, actual_cost_usd:($x.costUsd // 0), output:$out}'
      if [ "$status" = "ok" ] && ! grep -qE '\(429\)|RESOURCE_EXHAUSTED|\(503\)|high demand' <<<"$text"; then
        echo "$text" | tail -n 3; return 0
      fi
      msg="Continue the task from where you stopped (the previous model hit a provider limit). Do not redo steps that already succeeded; check git and GitHub state first."
      if grep -qE '\(429\)|RESOURCE_EXHAUSTED' <<<"$text"; then
        if [ -z "$retried" ]; then retried=1; sleep 65; continue; fi   # per-minute window
        # per-day quota: Gemini free tier resets at midnight Pacific (08:00 UTC in winter)
        printf '%s\t%s\n' "$m" "$(next_reset)" >> "$LEDGER"
      fi
      retried=""; break
    done
  done
  echo "all models exhausted for $agent; see $LEDGER"; return 1
}

# Merge decisions are human. When a ticket is ready-to-merge and both required statuses are
# success on its PR's current head, post the evidence once per head commit and stop there.
merge_decisions() {
  local n pr sha states
  for n in $(gh issue list --repo "$REPO" --state open --label status:ready-to-merge --json number --jq '.[].number'); do
    pr="$(pr_for "$n")"; [ -n "$pr" ] || continue
    sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
    states="$(gh api "repos/$REPO/commits/$sha/status" --jq '[.statuses[] | select(.context=="agent/review" or .context=="agent/test") | "\(.context)=\(.state)"] | sort | join(" ")')"
    [ "$states" = "agent/review=success agent/test=success" ] || continue
    gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body' | grep -q "Merge decision ready for ${sha:0:7}" && continue
    gh pr comment "$pr" --repo "$REPO" --body "[dispatcher] Merge decision ready for ${sha:0:7}: \`agent/review\` and \`agent/test\` are both success on the head commit; ticket #$n is \`status:ready-to-merge\`. Waiting for the human merge — agents do not merge." >/dev/null
    echo "merge decision ready: PR #$pr (#$n) at ${sha:0:7}"
  done
}

agent="${1:-next}"; n="${2:-}"
[ "$agent" = "next" ] && merge_decisions
if [ "$agent" = "next" ]; then
  read -r agent n <<<"$(route)"
  [ "$agent" = "idle" ] && { echo "idle: nothing actionable"; exit 0; }
  [ "$n" = "plan" ] && n=""
fi
case "$agent" in manager|reviewer)
  p="$(cat "$LOG/quota/hermes-paused-until" 2>/dev/null || echo 0)"
  [ "$p" -gt "$(date +%s)" ] && { echo "hermes paused for quota until $(date -u -d "@$p" +%FT%TZ)"; exit 0; }
  # Verify the reset with one tiny request to the agent's primary before starting a long
  # run; a rejected (429) request does not count against the free quota.
  if [ "$p" -gt 0 ]; then
    model="$(hermes -p "$agent" config get model.default)"
    code="$(set -a; . "$HOME/.secrets/agents.env"; curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
      -H "x-goog-api-key: $GEMINI_API_KEY_HERMES" -H 'content-type: application/json' \
      -d '{"contents":[{"parts":[{"text":"OK"}]}],"generationConfig":{"maxOutputTokens":5}}' \
      "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent")"
    if [ "$code" = "429" ]; then
      echo $(( $(date +%s) + 3600 )) > "$LOG/quota/hermes-paused-until"
      echo "quota reset not verified for $model (HTTP 429); paused 1h"; exit 0
    fi
    echo "quota reset verified for $model (HTTP $code)"; echo 0 > "$LOG/quota/hermes-paused-until"
  fi;;
esac
echo "== dispatch: $agent ${n:+#$n} ($(date -u +%FT%TZ))"

# Role prompts and helper scripts come from main; refresh them before every run.
SRC="$HOME/agents/_src"
git -C "$SRC" pull -q --ff-only || true
for id in manager reviewer; do cp "$SRC/agents/hermes/$id/SOUL.md" "$HOME/.hermes/profiles/$id/SOUL.md"; done
for id in backend ui tester; do cp "$SRC/agents/openclaw/$id/AGENTS.md" "$HOME/agents/$id/AGENTS.md"; done

labels_of() { [ -n "$1" ] && gh issue view "$1" --repo "$REPO" --json labels --jq '[.labels[].name] | sort | join(",")' || true; }
before="$(labels_of "$n")"
msg="$(prompt_for "$agent" "$n")"
rc=0
case "$agent" in
  manager|reviewer) run_hermes "$agent" "$n" "$msg" || rc=$?;;
  backend|ui|tester) run_openclaw "$agent" "$n" "$msg" || rc=$?;;
  *) echo "unknown agent: $agent"; exit 2;;
esac

# Loop guard: two completed runs that leave a ticket's labels unchanged mean the agent is
# stuck; park the ticket for the manager/human instead of spending more free quota on it.
if [ -n "$n" ] && [ "$rc" -eq 0 ]; then
  strikes="$LOG/strikes-$agent-$n"
  if [ "$(labels_of "$n")" = "$before" ]; then
    echo x >> "$strikes"
    if [ "$(wc -l < "$strikes")" -ge 2 ]; then
      gh issue edit "$n" --repo "$REPO" --add-label blocked >/dev/null
      gh issue comment "$n" --repo "$REPO" --body "[dispatcher] BLOCKED: two completed \`$agent\` runs left this ticket's labels unchanged ($before). Parked for the manager/human. Runs are logged in runs.jsonl." >/dev/null
      rm -f "$strikes"; echo "loop guard: #$n blocked"
    fi
  else
    rm -f "$strikes"
  fi
fi
exit "$rc"

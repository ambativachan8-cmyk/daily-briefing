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
  local head=""; [ -n "$pr" ] && head="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
  case "$agent" in
    manager)
      if [ -z "$n" ]; then
        echo "There are no open tickets. Plan the project: read docs/PRODUCT_BRIEF.md and agents/PROTOCOL.md in this clone, then create the tickets on GitHub as your SOUL.md describes. To save model calls, write all gh commands into one shell script and run it once. Finish with one line: PLANNED <issue numbers>."
      else
        echo "Ticket #$n needs you. Run: gh issue view $n --repo $REPO --comments${pr:+ and gh pr view $pr --repo $REPO --comments (the review and test verdicts are on the PR)}. Follow your SOUL.md: if it was sent back or is a bug, re-queue it to the right builder with a comment explaining why (or mark blocked after 3 retries); if it is held and its dependencies are merged, release it with status:ready. Then update the Delivery status issue. Finish with one line: TRIAGED #$n <action>."
      fi;;
    reviewer)
      echo "Issue #$n is in review; its PR is #${pr:-?} in $REPO, head commit $head. Free-tier quota allows about 6 model calls, so chain shell commands. First command, all at once: git fetch and check out exactly that commit (a verdict about any other commit is void); gh issue view $n --repo $REPO --comments; gh pr view ${pr:-?} --repo $REPO --comments; gh pr diff ${pr:-?} --repo $REPO; ~/agents/_src/scripts/verify_pr.sh ${pr:-?}. That script gives you real test output and HTTP responses for the 'Tests run' row. Then run your own probes in one command, and quote each command and result in the 'Own probes' row: a review with an empty row is void. Review as your SOUL.md says: post the evidence table first, then set the agent/review commit status on the PR head and move the ticket with ticket.sh. Finish with one line: REVIEWED #$n APPROVED|CHANGES_REQUESTED <PR url>.";;
    backend|ui|tester-build)
      echo "Work ticket #$n. Free-tier quota allows about 15 model calls for this ticket, so read only what you need, write whole files in one step, and chain shell commands (tests, commit, push, PR, ticket.sh) into one. Read AGENTS.md in your workspace and daily-briefing/agents/PROTOCOL.md, then run: gh issue view $n --repo $REPO --comments${pr:+ and gh pr view $pr --repo $REPO --comments}. If it was sent back, address every numbered point in the latest review/test comments and the manager's and human owner's notes, on the same branch and PR. Work inside ./daily-briefing. Finish with one line: DONE #$n <PR url> or BLOCKED #$n <reason>.";;
    tester)
      # status:testing = verify someone else's PR; any other state = the tester's own ticket
      if [ "$(gh issue view "$n" --repo "$REPO" --json labels --jq '[.labels[].name] | index("status:testing") != null')" != "true" ]; then
        prompt_for tester-build "$n"; return
      fi
      echo "Issue #$n passed review and is ready for testing; its PR is #${pr:-?} in $REPO, head commit $head; test exactly that commit. Free-tier quota allows about 4 model calls. Read AGENTS.md in your workspace and follow its steps: run ~/agents/_src/scripts/verify_pr.sh ${pr:-?} into a file, judge the output against gh issue view $n --repo $REPO, and post it with a first line of exactly: [openclaw-tester] Test of ${head:0:7} — PASS or FAIL. Then set agent/test on the PR head commit and move the ticket with ticket.sh, in one command. Finish with one line: TESTED #$n PASS|FAIL <PR url>.";;
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
  # A run that ended on provider limits did not complete its work. Ask the providers how long to
  # pause: a per-minute 429 must not park the whole team until tomorrow's reset.
  if [ "$rc" -ne 0 ] || ! jq -e '.completed == true and .failed != true' "$usage" >/dev/null 2>&1; then
    if grep -qiE 'free-models-per-day|429|RESOURCE_EXHAUSTED|rate.?limit|quota' "$out"; then
      local verdict until_ts
      read -r verdict until_ts _ <<<"$(probe_hermes "$agent" | tail -n 1)"
      if [ "$verdict" = "pause" ]; then echo "$until_ts" > "$LOG/quota/hermes-paused-until"
      else echo 0 > "$LOG/quota/hermes-paused-until"; fi
    fi
    return 1
  fi
}

# Gemini free tier resets at midnight Pacific (08:00 UTC in winter).
next_reset() {
  local t; t="$(date -u -d 'today 08:00' +%s)"
  [ "$t" -gt "$(date +%s)" ] || t="$(date -u -d 'tomorrow 08:00' +%s)"
  echo "$t"
}

# Which Gemini limit is hit for OpenClaw's key: prints "day" only for a per-day 429.
gemini_quota() {
  local body code; body="$(mktemp)"
  code="$(set -a; . "$HOME/.secrets/agents.env"; curl -s --max-time 30 -o "$body" -w '%{http_code}' \
    -H "x-goog-api-key: $GEMINI_API_KEY_OPENCLAW" -H 'content-type: application/json' \
    -d '{"contents":[{"parts":[{"text":"Reply with OK"}]}],"generationConfig":{"maxOutputTokens":16}}' \
    "https://generativelanguage.googleapis.com/v1beta/models/$1:generateContent" || true)"
  if [ "$code" = 429 ] && jq -e '[.error.details[]?.violations[]?.quotaId // ""] | any(test("PerDay"))' "$body" >/dev/null 2>&1
  then echo day; else echo other; fi
  rm -f "$body"
}

# OpenRouter's free daily limit resets at 00:00 UTC, not at Gemini's reset.
next_reset_for() { case "$1" in openrouter/*) date -u -d 'tomorrow 00:00' +%s;; *) next_reset;; esac; }

# OpenClaw does not switch models mid-turn once a tool has run (replay safety), so on a
# quota error we resume the same session on the next model with remaining free quota.
run_openclaw() {
  # One session per PR head: work interrupted by quota resumes with its context, and new commits
  # start clean and re-read GitHub. Replaying a whole earlier session cost 3.3M cache-read
  # tokens on one rework of #2.
  local head pr; pr="$(pr_for "${2:-0}")"; head="$([ -n "$pr" ] && gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid[0:7]' || echo none)"
  local agent="$1" n="$2" msg="$3" key="${DISPATCH_SESSION_KEY:-agent:$1:issue-${2:-0}:$head}" models m ts out status text retried="" waits=0
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
      text="$(jq -r '.result.payloads[-1].text // .error.message // .summary // ""' "$out" 2>/dev/null || true)
$(cat "${out%.json}.err" 2>/dev/null)"
      log_jsonl --arg ts "$ts" --arg a "$agent" --arg n "$n" --arg m "$m" --arg s "$status" --arg out "$out" \
        --slurpfile r <(cat "$out" 2>/dev/null || echo '{}') \
        '($r[0].result.meta.agentMeta // {}) as $x | {ts:$ts, agent:$a, framework:"openclaw", issue:$n,
          status:$s, model:$m, provider:$x.provider, assistant_turns:$x.assistantTurns,
          input_tokens:$x.usage.input, output_tokens:$x.usage.output, cache_read_tokens:$x.usage.cacheRead,
          total_tokens:$x.usage.total, actual_cost_usd:($x.costUsd // 0), output:$out}'
      if [ "$status" = "ok" ] && ! grep -qE '\(429\)|\| 429|RESOURCE_EXHAUSTED|\(503\)|high demand' <<<"$text"; then
        echo "$text" | tail -n 3; return 0
      fi
      msg="Continue the task from where you stopped (the previous model hit a provider limit). Do not redo steps that already succeeded; check git and GitHub state first. Commit and push finished work now, in case the limit returns."
      if grep -qE '\(429\)|\| 429|RESOURCE_EXHAUSTED' <<<"$text"; then
        # A 429 is usually the 5/min window. Ask Gemini which limit it is before writing off a
        # model for the day: a probe answered 200 straight after a model had been ledgered.
        case "$m" in
          google/*) [ "$(gemini_quota "${m#google/}")" = "day" ] || retried="" ;;
        esac
        if [ -z "$retried" ] && [ "$waits" -lt 20 ]; then retried=1; waits=$((waits + 1)); sleep 65; continue; fi
        # per-day quota: Gemini free tier resets at midnight Pacific (08:00 UTC in winter)
        printf '%s\t%s\n' "$m" "$(next_reset_for "$m")" >> "$LEDGER"
      fi
      retried=""; waits=0; break
    done
  done
  echo "all models exhausted for $agent; see $LEDGER"; return 1
}

# One tiny request per Gemini model in the agent's chain (primary first), stopping at the
# first real answer, so a probe costs at most one request of quota. Prints one of:
#   ok <model>                      HTTP 200 with non-empty generated text
#   pause <epoch> <reason>          nothing answered; retry at the soonest sensible time
# 429 per-day -> next reset; 429 per-minute -> 2 min; 401/403/404/400 (key or model
# problem, needs a human) -> 1 h; 5xx, timeout, network error, malformed 200 -> 15 min.
probe_hermes() {
  local agent="$1" m code body now t retry=0 reasons="" models
  models="$(hermes -p "$agent" config get model.default
            /usr/bin/python3 -c 'import sys, yaml
for e in (yaml.safe_load(open(sys.argv[1])) or {}).get("fallback_providers") or []:
    if e.get("provider") == "gemini": print(e["model"])' "$HOME/.hermes/profiles/$agent/config.yaml")"
  body="$(mktemp)"; now="$(date +%s)"
  for m in $models; do
    : > "$body"
    code="$(set -a; . "$HOME/.secrets/agents.env"; curl -s --max-time 30 -o "$body" -w '%{http_code}' \
      -H "x-goog-api-key: $GEMINI_API_KEY_HERMES" -H 'content-type: application/json' \
      -d '{"contents":[{"parts":[{"text":"Reply with OK"}]}],"generationConfig":{"maxOutputTokens":512}}' \
      "https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent" || true)"
    if [ "$code" = 200 ] && jq -e '[.candidates[0].content.parts[]?.text // empty] | join("") | length > 0' "$body" >/dev/null 2>&1; then
      echo "$(date -u +%FT%TZ) $agent $m 200 ok" >> "$LOG/quota/probes.log"
      rm -f "$body"; echo "ok $m"; return
    fi
    case "$code" in
      429) if jq -e '[.error.details[]?.violations[]?.quotaId // ""] | any(test("PerDay"))' "$body" >/dev/null 2>&1
           then t="$(next_reset)"; else t=$(( now + 120 )); fi;;
      400|401|403|404) t=$(( now + 3600 )); echo >&2 "ATTENTION: $agent probe of $m got HTTP $code: $(jq -r '.error.message // "no message"' "$body" 2>/dev/null | head -c 160)";;
      200) code="200-malformed"; t=$(( now + 900 ));;
      *) t=$(( now + 900 ));;   # 5xx, 000 = timeout/network
    esac
    echo "$(date -u +%FT%TZ) $agent $m $code" >> "$LOG/quota/probes.log"
    reasons="$reasons$m=$code,"
    { [ "$retry" -eq 0 ] || [ "$t" -lt "$retry" ]; } && retry="$t"
  done
  code="$(set -a; . "$HOME/.secrets/agents.env"; curl -s --max-time 40 -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'content-type: application/json' \
    -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b:free","messages":[{"role":"user","content":"Reply with OK"}],"max_tokens":16}' \
    https://openrouter.ai/api/v1/chat/completions || true)"
  echo "$(date -u +%FT%TZ) $agent openrouter $code" >> "$LOG/quota/probes.log"
  if [ "$code" = 200 ]; then rm -f "$body"; echo "ok openrouter"; return; fi
  rm -f "$body"
  echo "pause $retry ${reasons%,}"
}

# Merge decisions are human. A ticket is merge-ready only when, on its PR's exact current
# head commit, the newest agent/review and the newest agent/test status are both success
# (older or duplicate statuses on that commit are ignored; statuses on earlier commits never
# count). The evidence is posted once per head commit; nothing is merged here.
latest_gates() {   # <sha> -> "agent/review=<state> agent/test=<state>" from the newest status of each
  gh api --paginate "repos/$REPO/commits/$1/statuses?per_page=100" --jq '.[]' \
    | jq -rs '[.[] | select(.context == "agent/review" or .context == "agent/test")]
              | group_by(.context) | map(max_by([.created_at, .id]))
              | map("\(.context)=\(.state)") | sort | join(" ")'
}
# Does this PR's newest verdict comment for <sha> carry real evidence? Prints the gap, if any.
evidence_gap() {  # <pr> <sha>
  local sha7="${2:0:7}" comments review test
  comments="$(gh pr view "$1" --repo "$REPO" --json comments --jq '.comments[].body')"
  review="$(gh pr view "$1" --repo "$REPO" --json comments \
    --jq "[.comments[].body | select(contains(\"hermes-reviewer] Review of $sha7\"))] | last // empty")"
  [ -n "$review" ] || { echo "reviewer:no review comment for $sha7"; return; }
  grep -qE '^\| *Own probes.*`[^`]+`' <<<"$review" || { echo "reviewer:no quoted probes in the review of $sha7"; return; }
  test="$(gh pr view "$1" --repo "$REPO" --json comments \
    --jq "[.comments[].body | select(contains(\"openclaw-tester] Test of $sha7\"))] | last // empty")"
  grep -q "verify_pr head: $2" <<<"$test" || { echo "tester:no verify_pr output for $sha7"; return; }
}

# A review already approved and tested at this exact head needs no second test run.
skip_repeat_tests() {
  local n pr sha
  for n in $(gh issue list --repo "$REPO" --state open --label status:testing --json number --jq '.[].number'); do
    pr="$(pr_for "$n")"; [ -n "$pr" ] || continue
    sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
    [ "$(latest_gates "$sha")" = "agent/review=success agent/test=success" ] && [ -z "$(evidence_gap "$pr" "$sha")" ] || continue
    "$HOME/agents/_src/scripts/ticket.sh" move "$n" ready-to-merge manager >/dev/null
    echo "#$n: tests already passed at ${sha:0:7}; no repeat test run"
  done
}

merge_decisions() {
  local n pr sha gates evidence gap who what stage
  for n in $(gh issue list --repo "$REPO" --state open --label status:ready-to-merge --json number --jq '.[].number'); do
    pr="$(pr_for "$n")"; [ -n "$pr" ] || continue
    sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
    gates="$(latest_gates "$sha")"
    [ "$gates" = "agent/review=success agent/test=success" ] || { echo "PR #$pr not merge-ready at ${sha:0:7}: ${gates:-no gate statuses}"; continue; }
    # A green status without its evidence for this head is not a verdict: send it back once,
    # then park it for the human.
    gap="$(evidence_gap "$pr" "$sha")"
    if [ -n "$gap" ]; then
      who="${gap%%:*}"; what="${gap#*:}"
      if gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body' | grep -qF "[dispatcher] $what"; then
        gh issue edit "$n" --repo "$REPO" --add-label blocked >/dev/null
      else
        gh pr comment "$pr" --repo "$REPO" --body "[dispatcher] $what. A green status without its evidence is not a verdict. Returned to the $who." >/dev/null
        if [ "$who" = reviewer ]; then stage=in-review; else stage=testing; fi
        "$HOME/agents/_src/scripts/ticket.sh" move "$n" "$stage" "$who" >/dev/null
      fi
      continue
    fi
    # the head must not have moved while we checked
    [ "$(gh pr view "$pr" --repo "$REPO" --json state,headRefOid --jq '.state + " " + .headRefOid')" = "OPEN $sha" ] || continue
    gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body' | grep -q "Merge decision ready for $sha" && continue
    evidence="$(gh api --paginate "repos/$REPO/commits/$sha/statuses?per_page=100" --jq '.[]' \
      | jq -rs 'group_by(.context) | map(max_by([.created_at, .id])) | .[]
                | select(.context == "agent/review" or .context == "agent/test")
                | "- `\(.context)` = **\(.state)** at \(.created_at) (status id \(.id)): \(.description)"')"
    gh pr comment "$pr" --repo "$REPO" --body "[dispatcher] Merge decision ready for $sha

Newest gate statuses on this exact head commit:
$evidence

Ticket #$n is \`status:ready-to-merge\`. Waiting for the human merge — agents do not merge." >/dev/null
    echo "merge decision ready: PR #$pr (#$n) at $sha"
  done
}

agent="${1:-next}"; n="${2:-}"
[ "$agent" = "next" ] && { skip_repeat_tests; merge_decisions; }
if [ "$agent" = "next" ]; then
  read -r agent n <<<"$(route)"
  [ "$agent" = "idle" ] && { echo "idle: nothing actionable"; exit 0; }
  [ "$n" = "plan" ] && n=""
fi
case "$agent" in manager|reviewer)
  p="$(cat "$LOG/quota/hermes-paused-until" 2>/dev/null || echo 0)"
  [ "$p" -gt "$(date +%s)" ] && { echo "hermes paused for quota until $(date -u -d "@$p" +%FT%TZ)"; exit 0; }
  # After a pause, resume only when a probe gets a real answer from Gemini.
  if [ "$p" -gt 0 ]; then
    read -r verdict a b <<<"$(probe_hermes "$agent" | tail -n 1)"
    if [ "$verdict" != "ok" ]; then
      echo "$a" > "$LOG/quota/hermes-paused-until"
      echo "quota reset not verified ($b); paused until $(date -u -d "@$a" +%FT%TZ)"; exit 0
    fi
    echo "quota reset verified: $a answered"; echo 0 > "$LOG/quota/hermes-paused-until"
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

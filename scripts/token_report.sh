#!/usr/bin/env bash
# Builds docs/TOKEN_REPORT.md from the dispatcher's per-run log (~/logs/usage/runs.jsonl).
# Token counts are what each runtime reported for the run. Hermes' dollar figure is its own
# list-price estimate; actual spend is $0 (free-tier keys, OpenRouter key limit $0).
set -euo pipefail
IN="${1:-$HOME/logs/usage/runs.jsonl}"
OUT="${2:-$HOME/agents/_src/docs/TOKEN_REPORT.md}"

{
  echo "# Token usage report"
  echo
  echo "Generated $(date -u +%FT%TZ) from \`runs.jsonl\` ($(wc -l < "$IN") run attempts)."
  echo "Counts are reported by the runtimes themselves (Hermes \`--usage-file\`, OpenClaw"
  echo "\`--json\` agent meta). **Actual cost: \$0** — every key is free tier. The \"list-price"
  echo "estimate\" column is Hermes' own estimate of what the same tokens would cost on a paid"
  echo "plan; OpenClaw reports \`costUsd: 0\` for these models. Model calls are exact for Hermes"
  echo "(\`api_calls\`); for OpenClaw the column shows assistant turns, a lower bound."
  echo
  echo "## By agent and model"
  echo
  echo "| Agent | Framework | Model | Runs | Model calls | Input tokens | Output tokens | Cache-read | Total | List-price estimate (USD) |"
  echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"
  jq -rs 'map(.model |= sub("^(google|openrouter)/"; "")) | group_by([.agent, .model]) | .[] |
    [ .[0].agent, .[0].framework, (.[0].model // "?"), length,
      (map(.api_calls // .assistant_turns // 0) | add),
      (map(.input_tokens // 0) | add), (map(.output_tokens // 0) | add),
      (map(.cache_read_tokens // 0) | add), (map(.total_tokens // 0) | add),
      ((map(.list_price_estimate_usd // 0) | add) * 10000 | round / 10000) ]
    | "| " + (map(tostring) | join(" | ")) + " |"' "$IN"
  echo
  echo "## By agent"
  echo
  echo "| Agent | Runs | Total tokens | Failed attempts (quota/provider) |"
  echo "|---|---:|---:|---:|"
  jq -rs 'group_by(.agent) | .[] |
    "| \(.[0].agent) | \(length) | \(map(.total_tokens // 0) | add) | \(map(select((.status // "ok") != "ok" or (.exit // 0) != 0)) | length) |"' "$IN"
  echo
  echo "## By phase"
  echo
  echo "Each attempt counts once. An agent's first successful run on a ticket goes to its phase"
  echo "(manager: planning; backend, ui: coding; reviewer, tester: review/test). Every other attempt"
  echo "(a failed attempt, or a repeat run on the same ticket, such as a re-review or rework after a"
  echo "send-back) counts as a retry. Fresh tokens exclude cache reads, which the two runtimes report"
  echo "differently: OpenClaw's input excludes them and Hermes' input includes them."
  echo
  echo "| Phase | Attempts | Fresh tokens | Cache-read | Total reported |"
  echo "|---|---:|---:|---:|---:|"
  jq -rs 'def ok: (.status // "ok") == "ok" and (.exit // 0) == 0;
    def fresh: if .framework == "hermes" then ((.input_tokens // 0) - (.cache_read_tokens // 0) + (.output_tokens // 0))
               else ((.input_tokens // 0) + (.output_tokens // 0)) end;
    reduce .[] as $r ({seen: {}, rows: []};
      ($r.agent + "/" + ($r.issue // "")) as $k
      | (if ($r | ok) and (.seen[$k] | not) then
           ({manager: "planning", backend: "coding", ui: "coding", reviewer: "review/test", tester: "review/test"}[$r.agent])
         else "retries" end) as $phase
      | (if ($r | ok) then .seen[$k] = true else . end)
      | .rows += [$r + {phase: $phase, fresh: ($r | fresh)}])
    | .rows | group_by(.phase) | .[] |
    "| \(.[0].phase) | \(length) | \(map(.fresh) | add) | \(map(.cache_read_tokens // 0) | add) | \(map(.total_tokens // 0) | add) |"' "$IN"
  echo
  echo "## Every run"
  echo
  echo "| Time (UTC) | Agent | Ticket | Model | Status | Total tokens |"
  echo "|---|---|---|---|---|---:|"
  jq -r '"| \(.ts) | \(.agent) | \(if .issue == "" then "plan" else "#" + .issue end) | \(.model // "?") | \(.status // (if .exit == 0 then "ok" else "exit " + (.exit|tostring) end)) | \(.total_tokens // 0) |"' "$IN"
} > "$OUT"
echo "wrote $OUT"

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
  jq -rs 'group_by([.agent, .model]) | .[] |
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
  echo "## Every run"
  echo
  echo "| Time (UTC) | Agent | Ticket | Model | Status | Total tokens |"
  echo "|---|---|---|---|---|---:|"
  jq -r '"| \(.ts) | \(.agent) | \(if .issue == "" then "plan" else "#" + .issue end) | \(.model // "?") | \(.status // (if .exit == 0 then "ok" else "exit " + (.exit|tostring) end)) | \(.total_tokens // 0) |"' "$IN"
} > "$OUT"
echo "wrote $OUT"

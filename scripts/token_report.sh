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
  echo "Generated $(date -u +%FT%TZ) from [\`docs/evidence/runs.jsonl\`](evidence/runs.jsonl) ($(wc -l < "$IN") run attempts)."
  echo "Rebuild it yourself: \`bash scripts/token_report.sh docs/evidence/runs.jsonl /tmp/report.md\` (needs \`jq\`)."
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
  jq -rs 'map(.model |= sub("^(google|openrouter|nvidia)/"; "")) | group_by([.agent, .model]) | .[] |
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
  echo "Fresh plus cache-read can exceed the total on the retries row: some failed Hermes runs report"
  echo "input tokens but a total of 0. The totals are the runtimes' own figures and are not adjusted."
  echo
  echo "## By phase, per agent and per model"
  echo
  echo "Total reported tokens. \"Repeat runs\" are successful runs after an agent's first on the same ticket"
  echo "(re-reviews of a new head, rework after a send-back). \"Failed attempts\" ended in a quota or provider"
  echo "error or a non-zero exit. The \"retries\" row above is these two columns added together, so it mixes"
  echo "normal rework with waste."
  echo
  for key in agent model; do
    echo "| $key | Planning | Coding | Review/test | Repeat runs | Failed attempts | Total |"
    echo "|---|---:|---:|---:|---:|---:|---:|"
    jq -rs --arg key "$key" 'def ok: (.status // "ok") == "ok" and (.exit // 0) == 0;
      map(.model |= ((. // "?") | sub("^(google|openrouter|nvidia)/"; "")))
      | reduce .[] as $r ({seen: {}, rows: []};
          ($r.agent + "/" + ($r.issue // "")) as $k
          | (if ($r | ok) | not then "failed attempts" elif .seen[$k] then "repeat runs"
             else {manager: "planning", backend: "coding", ui: "coding", reviewer: "review/test", tester: "review/test"}[$r.agent] end) as $phase
          | (if ($r | ok) then .seen[$k] = true else . end)
          | .rows += [$r + {phase: $phase}])
      | .rows | group_by(.[$key]) | .[] | . as $g
      | "| \(.[0][$key]) | " + (["planning", "coding", "review/test", "repeat runs", "failed attempts"]
          | map(. as $p | $g | map(select(.phase == $p) | .total_tokens // 0) | add // 0 | tostring) | join(" | "))
        + " | \($g | map(.total_tokens // 0) | add) |"' "$IN"
    echo
  done
  echo "## Not counted anywhere in this report"
  echo
  echo "The operator's own model use (Claude Code and Codex, used for planning, setup, gate scripts, audits and"
  echo "review findings) is outside this log and was not measured. It was a strong model doing real work, so"
  echo "these tables understate the true cost of the delivery. See DELIVERY.md, section 1."
  echo
  echo "## Not in the counts above: OpenClaw on NVIDIA (estimate)"
  echo
  echo "OpenClaw reports zero tokens for NVIDIA's API, so its UI builder and tester runs on NVIDIA add 0 to"
  echo "every table above, though their turn counts are real. **This is an estimate:** those turns multiplied"
  echo "by the average tokens per turn of OpenClaw runs that did report usage. Hermes reports NVIDIA usage"
  echo "normally, so it is already counted."
  echo
  jq -rs '(map(select(.framework == "openclaw" and (.total_tokens // 0) > 0 and (.assistant_turns // 0) > 0))) as $m
    | ($m | map(.assistant_turns) | add) as $turns | ($m | map(.total_tokens) | add) as $tok
    | ($m | map((.input_tokens // 0) + (.output_tokens // 0)) | add) as $fresh
    | map(select(.framework == "openclaw" and ((.model // "") | test("^nvidia/(nvidia|z-ai)/")))) | group_by(.agent) | map({agent: .[0].agent, turns: (map(.assistant_turns // 0) | add)})
    | "| Agent | Turns on NVIDIA | Estimated total tokens | Of which fresh |\n|---|---:|---:|---:|\n"
      + (map("| \(.agent) | \(.turns) | ~\((.turns * $tok / $turns / 1000 | round) * 1000) | ~\((.turns * $fresh / $turns / 1000 | round) * 1000) |") | join("\n"))
      + "\n\nAverage from \($turns) measured turns: \($tok / $turns | round) total and \($fresh / $turns | round) fresh tokens per turn."' "$IN"
  echo
  echo "## Every run"
  echo
  echo "| Time (UTC) | Agent | Ticket | Model | Status | Total tokens |"
  echo "|---|---|---|---|---|---:|"
  jq -r '"| \(.ts) | \(.agent) | \(if .issue == "" then "plan" else "#" + .issue end) | \(.model // "?") | \(.status // (if .exit == 0 then "ok" else "exit " + (.exit|tostring) end)) | \(.total_tokens // 0) |"' "$IN"
} > "$OUT"
echo "wrote $OUT"

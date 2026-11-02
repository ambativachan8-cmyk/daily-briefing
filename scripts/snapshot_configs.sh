#!/usr/bin/env bash
# Copies each agent's live runtime config into agents/<runtime>/<id>/ with secrets removed.
# Run on the VM inside a clone; review the diff before committing.
set -euo pipefail
OUT="${1:-$HOME/agents/_src/agents}"
redact() {
  sed -E -e 's/(sk-or-|github_pat_|gh[pousr]_|AQ\.|AIza)[A-Za-z0-9._-]+/<redacted>/g' \
         -e 's/("?(token|apiKey|api_key|secret|password)"?[[:space:]]*[:=][[:space:]]*)"[^"]+"/\1"<redacted>"/Ig'
}
for id in manager reviewer; do
  redact < "$HOME/.hermes/profiles/$id/config.yaml" > "$OUT/hermes/$id/config.yaml"
done
jq '.gateway.auth.token = "<redacted>"' "$HOME/.openclaw/openclaw.json" | redact > "$OUT/openclaw/openclaw.json"
# Fail loudly if anything key-shaped survived.
if grep -rEn '(sk-or-|github_pat_|AQ\.A|AIza)[A-Za-z0-9]' "$OUT"; then echo "secret-like string found" >&2; exit 1; fi
echo "snapshots written to $OUT"

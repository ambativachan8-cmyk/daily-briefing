#!/usr/bin/env bash
# Wires model credentials and the per-agent model plan into the five agents.
# Reads keys from ~/.secrets/agents.env (chmod 600, never committed); idempotent.
#
# Every model below answered a live call on 2026-11-03 with free-tier keys
# (Gemini quota ids *-FreeTier; OpenRouter key has a $0 limit). Primaries are
# spread across models because Gemini free quota is per model per project.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

SECRETS="$HOME/.secrets/agents.env"
set -a; . "$SECRETS"; set +a
OR_FALLBACK="nvidia/nemotron-3-ultra-550b-a55b:free"

# gh (and git push, via `gh auth setup-git`) for every agent. Hermes strips
# secrets from tool subprocess env, so the token lives in gh's own 600 store.
printf '%s\n' "$GH_TOKEN" | env -u GH_TOKEN gh auth login --with-token --hostname github.com

# ---- Hermes: manager, reviewer (Gemini key "HERMES") --------------------------
# Free tier is 5 req/min per model: chain other Gemini models before OpenRouter
# (50 free req/day), and wait out a short per-minute window instead of switching.
declare -A H_PRIMARY=([manager]="gemini-3.5-flash" [reviewer]="gemini-3.6-flash")
declare -A H_FALLBACK=([manager]="gemini-3-flash-preview,gemini-3.6-flash,gemini-3.5-flash-lite"
                       [reviewer]="gemini-3.5-flash,gemini-3-flash-preview,gemini-3.5-flash-lite")
HPY=/usr/bin/python3   # system python; PyYAML ships with cloud-init on Ubuntu

for id in manager reviewer; do
  P="$HOME/.hermes/profiles/$id"
  umask 077
  cat > "$P/.env" <<EOF
GOOGLE_API_KEY=$GEMINI_API_KEY_HERMES
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
GH_TOKEN=$GH_TOKEN
EOF
  chmod 600 "$P/.env"
  hermes -p "$id" config set model.provider gemini >/dev/null
  hermes -p "$id" config set model.default "${H_PRIMARY[$id]}" >/dev/null
  hermes -p "$id" config unset model.base_url >/dev/null 2>&1 || true
  "$HPY" - "$P/config.yaml" "${H_FALLBACK[$id]}" "$OR_FALLBACK" <<'PY'
import sys, yaml
path, gems, orm = sys.argv[1:]
cfg = yaml.safe_load(open(path)) or {}
cfg["fallback_providers"] = ([{"provider": "gemini", "model": m} for m in gems.split(",")]
                             + [{"provider": "openrouter", "model": orm}])
cfg.setdefault("fallback", {})["min_switch_reset_seconds"] = 90
yaml.safe_dump(cfg, open(path, "w"), sort_keys=False)
PY
done

# ---- OpenClaw: backend, ui, tester (Gemini key "OPENCLAW") --------------------
umask 077
cat > "$HOME/.openclaw/.env" <<EOF
GEMINI_API_KEY=$GEMINI_API_KEY_OPENCLAW
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
GH_TOKEN=$GH_TOKEN
EOF
chmod 600 "$HOME/.openclaw/.env"

OR="openrouter/$OR_FALLBACK"
cat > /tmp/openclaw-models.json5 <<EOF
{ tools: { profile: "coding" },
  agents: { entries: {
  backend: { model: { primary: "google/gemini-3.5-flash",
                      fallbacks: ["google/gemini-3.6-flash", "google/gemini-3-flash-preview", "google/gemini-3.5-flash-lite", "$OR"] } },
  ui:      { model: { primary: "google/gemini-3-flash-preview",
                      fallbacks: ["google/gemini-3.5-flash", "google/gemini-3.6-flash", "google/gemini-3.5-flash-lite", "$OR"] } },
  tester:  { model: { primary: "google/gemini-3.6-flash",
                      fallbacks: ["google/gemini-3-flash-preview", "google/gemini-3.5-flash-lite", "$OR"] } },
} } }
EOF
openclaw config patch --file /tmp/openclaw-models.json5
rm -f /tmp/openclaw-models.json5
systemctl --user restart openclaw-gateway.service 2>/dev/null || openclaw gateway restart

echo "== models"
for id in manager reviewer; do echo "hermes/$id: $(hermes -p "$id" config get model.default)"; done
for id in backend ui tester; do echo "openclaw/$id: $(openclaw config get "agents.entries.$id.model" 2>/dev/null | tr -d '\n ')"; done

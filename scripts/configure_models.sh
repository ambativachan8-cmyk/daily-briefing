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
#
# Measured 2026-11-05: quota buckets are shared across model names. A gemini-3.5-flash call is
# charged to gemini-3.6-flash, and gemini-3.7-flash to gemini-3.8-flash, so each pair appears once.
# Flash-lite allows 500 requests/day per project against flash's 20 (429 quotaValue, 2026-11-05).
# It is the abundant tier and flash is the scarce one, so the reviewer takes flash first and lite
# last. A lite model once approved work a flash model rejected, so a lite approval
# has to carry quoted probes and clean-checkout output, which the dispatcher checks, and the human
# verifies independently before merging. The manager's remaining work is routine triage.
#
# NVIDIA's hosted API comes first when its key is set (free, no daily cap observed). Tested
# 2026-11-05 with a 31k-token prompt and a tool: nemotron-3-ultra called it correctly in 3.5 s and
# glm-5.3-flash in 10 s. deepseek-v4.1-flash took 78 s; kimi-k2.6 returned 404 on this account.
# Nemotron does the judgement work, and it is the model that already drove both runtimes through
# OpenRouter. GLM takes routine triage and testing, and each is the other's fallback.
NV_STRONG="nvidia/nemotron-3-ultra-550b-a55b"
NV_ROUTINE="z-ai/glm-5.3-flash"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
declare -A H_PRIMARY=([manager]="gemini-3.5-flash-lite" [reviewer]="gemini-3-flash-preview")
declare -A H_FALLBACK=([manager]="gemini-3.1-flash-lite"
                       [reviewer]="gemini-3.8-flash,gemini-3.6-flash,gemini-3.5-flash-lite,gemini-3.1-flash-lite")
HPY=/usr/bin/python3   # system python; PyYAML ships with cloud-init on Ubuntu

for id in manager reviewer; do
  P="$HOME/.hermes/profiles/$id"
  umask 077
  cat > "$P/.env" <<EOF
GOOGLE_API_KEY=$GEMINI_API_KEY_HERMES
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
NVIDIA_API_KEY=$NVIDIA_API_KEY
GH_TOKEN=$GH_TOKEN
EOF
  chmod 600 "$P/.env"
  # NVIDIA chain for this role: primary, then fallback. Empty when no key is set.
  NV_CHAIN=""
  if [ -n "$NVIDIA_API_KEY" ]; then
    if [ "$id" = manager ]; then NV_CHAIN="$NV_ROUTINE,$NV_STRONG"; else NV_CHAIN="$NV_STRONG,$NV_ROUTINE"; fi
    hermes -p "$id" config set model.provider nvidia >/dev/null
    hermes -p "$id" config set model.default "${NV_CHAIN%%,*}" >/dev/null
  else
    hermes -p "$id" config set model.provider gemini >/dev/null
    hermes -p "$id" config set model.default "${H_PRIMARY[$id]}" >/dev/null
  fi
  hermes -p "$id" config unset model.base_url >/dev/null 2>&1 || true
  "$HPY" - "$P/config.yaml" "${H_PRIMARY[$id]},${H_FALLBACK[$id]}" "$OR_FALLBACK" "${NV_CHAIN#*,}" "$NVIDIA_API_KEY" <<'PY'
import sys, yaml
path, gems, orm, nv_next, nv_key = sys.argv[1:]
cfg = yaml.safe_load(open(path)) or {}
chain = [m for m in gems.split(",")]
if not nv_key:
    chain = chain[1:]   # the first Gemini model is already the primary
cfg["fallback_providers"] = (([{"provider": "nvidia", "model": nv_next}] if nv_key else [])
                             + [{"provider": "gemini", "model": m} for m in chain]
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
NVIDIA_API_KEY=$NVIDIA_API_KEY
GH_TOKEN=$GH_TOKEN
EOF
chmod 600 "$HOME/.openclaw/.env"

OR="openrouter/$OR_FALLBACK"
G="google/gemini"
BACKEND=("$G-3.6-flash" "$G-3.8-flash" "$G-3-flash-preview" "$G-3.5-flash-lite" "$G-3.1-flash-lite" "$OR")
UI=("$G-3.8-flash" "$G-3.6-flash" "$G-3-flash-preview" "$G-3.5-flash-lite" "$G-3.1-flash-lite" "$OR")
TESTER=("$G-3.5-flash-lite" "$G-3.1-flash-lite" "$OR")
if [ -n "$NVIDIA_API_KEY" ]; then
  BACKEND=("nvidia/$NV_STRONG" "nvidia/$NV_ROUTINE" "${BACKEND[@]}")
  UI=("nvidia/$NV_STRONG" "nvidia/$NV_ROUTINE" "${UI[@]}")
  TESTER=("nvidia/$NV_ROUTINE" "nvidia/$NV_STRONG" "${TESTER[@]}")
fi
model_json() {  # <model>...: first is the primary, the rest are fallbacks
  local primary="$1"; shift
  printf '{ primary: "%s", fallbacks: [' "$primary"
  printf '"%s", ' "$@"
  printf '] }'
}
cat > /tmp/openclaw-models.json5 <<EOF
{ tools: { profile: "coding" },
  agents: { entries: {
  backend: { model: $(model_json "${BACKEND[@]}") },
  ui:      { model: $(model_json "${UI[@]}") },
  tester:  { model: $(model_json "${TESTER[@]}") },
} } }
EOF
openclaw config patch --file /tmp/openclaw-models.json5
rm -f /tmp/openclaw-models.json5
systemctl --user restart openclaw-gateway.service 2>/dev/null || openclaw gateway restart

echo "== models"
for id in manager reviewer; do echo "hermes/$id: $(hermes -p "$id" config get model.default)"; done
for id in backend ui tester; do echo "openclaw/$id: $(openclaw config get "agents.entries.$id.model" 2>/dev/null | tr -d '\n ')"; done

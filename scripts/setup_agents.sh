#!/usr/bin/env bash
# Creates the five agent identities. Runs as the `agent` account (see install_all.sh). Idempotent; run
# after vm_bootstrap.sh. configure_models.sh then logs gh in and connects git to it.
#
#   ~/agents/<id>/                 agent workspace (role prompt lives here)
#   ~/agents/<id>/daily-briefing/  the agent's own clone, own git author, no pushes to main
#
# Hermes:   profiles `manager`, `reviewer`  (~/.hermes/profiles/<id>/SOUL.md)
# OpenClaw: agents   `backend`, `ui`, `tester` (Gateway on loopback only)
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

REPO_URL="https://github.com/ambativachan8-cmyk/daily-briefing.git"
SRC="$HOME/agents/_src"   # the agents' copy of the repo, used to source prompts; it has no authority

declare -A NAME=(
  [manager]="Hermes Manager"   [reviewer]="Hermes Reviewer"
  [backend]="OpenClaw Backend Builder" [ui]="OpenClaw UI Builder" [tester]="OpenClaw Tester"
)
declare -A EMAIL=(
  [manager]="hermes-manager@agents.daily-briefing.invalid"
  [reviewer]="hermes-reviewer@agents.daily-briefing.invalid"
  [backend]="openclaw-backend@agents.daily-briefing.invalid"
  [ui]="openclaw-ui@agents.daily-briefing.invalid"
  [tester]="openclaw-tester@agents.daily-briefing.invalid"
)

if [ -d "$SRC/.git" ]; then git -C "$SRC" pull -q --ff-only || true; else git clone -q "$REPO_URL" "$SRC"; fi

make_workspace() {
  local id="$1" ws="$HOME/agents/$1" clone="$HOME/agents/$1/daily-briefing"
  mkdir -p "$ws"
  [ -d "$clone/.git" ] || git clone -q "$REPO_URL" "$clone"
  git -C "$clone" config user.name  "${NAME[$id]}"
  git -C "$clone" config user.email "${EMAIL[$id]}"
  cat > "$clone/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
# Agents never push to main: work reaches main only through a reviewed, tested PR.
while read -r _ _ remote_ref _; do
  if [ "$remote_ref" = "refs/heads/main" ]; then
    echo "pre-push: direct push to main is blocked for agents; open a PR" >&2
    exit 1
  fi
done
HOOK
  chmod +x "$clone/.git/hooks/pre-push"
}

for id in manager reviewer backend ui tester; do make_workspace "$id"; done

# ---- Hermes profiles ----------------------------------------------------------
for id in manager reviewer; do
  [ -d "$HOME/.hermes/profiles/$id" ] || hermes profile create "$id" --description "${NAME[$id]}"
  cp "$SRC/agents/hermes/$id/SOUL.md" "$HOME/.hermes/profiles/$id/SOUL.md"
done

# ---- OpenClaw -----------------------------------------------------------------
if [ ! -f "$HOME/.openclaw/openclaw.json" ]; then
  # --accept-risk: agents get shell access; this VM is dedicated to them.
  openclaw onboard --non-interactive --accept-risk --mode local \
    --auth-choice skip --gateway-bind loopback --install-daemon \
    --skip-channels --skip-bootstrap
fi
# tester-judge is the tester's verdict mode: same model plan, no tools (see configure_models.sh).
mkdir -p "$HOME/agents/tester-judge"
for id in backend ui tester tester-judge; do
  if ! openclaw agents list --json 2>/dev/null | grep -q "\"$id\""; then
    openclaw agents add "$id" --non-interactive --workspace "$HOME/agents/$id"
  fi
  cp "$SRC/agents/openclaw/$id/AGENTS.md" "$HOME/agents/$id/AGENTS.md"
done

echo "== agents"
hermes profile list 2>/dev/null || true
openclaw agents list 2>/dev/null || true

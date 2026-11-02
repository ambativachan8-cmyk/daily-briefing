#!/usr/bin/env bash
# Creates the five agent identities on the VM. Idempotent; run after vm_bootstrap.sh.
#
#   ~/agents/<id>/                 agent workspace (role prompt lives here)
#   ~/agents/<id>/daily-briefing/  the agent's own clone, own git author, no pushes to main
#
# Hermes:   profiles `manager`, `reviewer`  (~/.hermes/profiles/<id>/SOUL.md)
# OpenClaw: agents   `backend`, `ui`, `tester` (Gateway on loopback only)
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

REPO_URL="https://github.com/ambativachan8-cmyk/daily-briefing.git"
SRC="$HOME/agents/_src"   # read-only copy of the repo used to source prompts

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

if [ -d "$SRC/.git" ]; then git -C "$SRC" pull -q --ff-only; else git clone -q "$REPO_URL" "$SRC"; fi

# git over HTTPS authenticates through gh, which reads GH_TOKEN from each agent's env
gh auth setup-git >/dev/null 2>&1 || true

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
for id in backend ui tester; do
  if ! openclaw agents list --json 2>/dev/null | grep -q "\"$id\""; then
    openclaw agents add "$id" --non-interactive --workspace "$HOME/agents/$id"
  fi
  cp "$SRC/agents/openclaw/$id/AGENTS.md" "$HOME/agents/$id/AGENTS.md"
done

echo "== agents"
hermes profile list 2>/dev/null || true
openclaw agents list 2>/dev/null || true

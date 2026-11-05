#!/usr/bin/env bash
# One-time moves for a VM set up before the security boundary existed. A fresh VM never needs this.
#
#   migrate_existing_vm.sh app       the live app from the ~/app checkout to staged releases, keeping its database
#   migrate_existing_vm.sh agents    OpenClaw, Hermes and the agent clones from `ubuntu` to the `agent` account
#
# Nothing is deleted. ~/app, ~/.hermes, ~/.openclaw and ~/agents/<id> stay in place as the original evidence,
# now out of the agents' reach.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
AGENT_HOME=/home/agent

as_agent() {
  sudo -n -u agent -H env -i HOME="$AGENT_HOME" USER=agent LOGNAME=agent LANG=C.UTF-8 \
    XDG_RUNTIME_DIR="/run/user/$(id -u agent)" \
    PATH="$AGENT_HOME/.local/bin:$AGENT_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

migrate_app() {
  local root="$HOME/deploy" sha
  [ ! -e "$root/state/deployed_sha" ] || { echo "already migrated: $(cat "$root/state/deployed_sha")"; return 0; }
  sha="$(git -C "$HOME/app" rev-parse HEAD)"
  # Same commit as the live app, staged beside it. The build and startup check touch nothing that serves.
  mkdir -p "$root/state" "$root/releases" "$root/shared/data" "$root/shared/backups"
  [ -d "$root/repo.git" ] || git init -q --bare "$root/repo.git"
  git -C "$root/repo.git" fetch -q --force https://github.com/ambativachan8-cmyk/daily-briefing.git "+refs/heads/main:refs/heads/main"
  git -C "$root/repo.git" fetch -q --force https://github.com/ambativachan8-cmyk/daily-briefing.git "$sha"
  DEPLOY_MANAGE_CADDY=no bash "$HERE/deploy_app.sh" --stage-only "$sha"
  # The cutover: a few seconds, then the same data under the new layout.
  systemctl --user stop daily-briefing.service
  sqlite3 "$HOME/app/data/briefing.db" ".backup '$root/shared/data/briefing.db'"
  DEPLOY_MANAGE_CADDY=no bash "$HERE/deploy_app.sh" --activate-only "$sha"
  systemctl --user is-active daily-briefing.service
  curl -fsS http://127.0.0.1:8000/health; echo
}

migrate_agents() {
  bash "$HERE/install_gate.sh"
  systemctl --user disable --now openclaw-gateway.service 2>/dev/null || true
  local item
  for item in .openclaw .hermes .npm-global .local; do
    sudo rsync -a --delete --exclude='.env' --exclude='.env.*' --exclude='auth.json' "$HOME/$item/" "$AGENT_HOME/$item/"
  done
  sudo mkdir -p "$AGENT_HOME/agents"
  for item in manager reviewer backend ui tester; do
    sudo rsync -a --delete "$HOME/agents/$item/" "$AGENT_HOME/agents/$item/"
  done
  [ -d "$AGENT_HOME/agents/_src/.git" ] || sudo git clone -q https://github.com/ambativachan8-cmyk/daily-briefing.git "$AGENT_HOME/agents/_src"
  # Same revision as the control plane, so prompts and ticket.sh match during the move.
  sudo git -C "$AGENT_HOME/agents/_src" -c safe.directory='*' fetch -q origin "$(git -C "$HERE/.." rev-parse HEAD)"
  sudo git -C "$AGENT_HOME/agents/_src" -c safe.directory='*' checkout -q --detach "$(git -C "$HERE/.." rev-parse HEAD)"

  # Paths: symlinks, then text files. Session history keeps its old paths on purpose: it is a record.
  sudo find "$AGENT_HOME" -xdev -type l -lname '/home/ubuntu/*' -print0 | while IFS= read -r -d '' link; do
    target="$(sudo readlink "$link")"; sudo ln -sfn "${target/#\/home\/ubuntu/$AGENT_HOME}" "$link"
  done
  sudo grep -rlI --null --exclude-dir=daily-briefing --exclude-dir=_src --exclude-dir=sessions --exclude-dir=logs --exclude-dir=node_modules --exclude-dir=__pycache__ \
    --exclude='*.db' --exclude='*.jsonl' '/home/ubuntu' "$AGENT_HOME" | sudo xargs -0 -r sed -i 's#/home/ubuntu#/home/agent#g'
  sudo chown -R agent:agent "$AGENT_HOME"
  sudo chmod 750 "$AGENT_HOME"

  # No file the agents can read may hold the control token. Prints paths and counts only.
  sudo python3 -I - "$HOME/.secrets/agents.env" "$AGENT_HOME" <<'PY'
import os, sys
token = b""
for line in open(sys.argv[1], "rb"):
    if line.startswith(b"GH_TOKEN="):
        token = line.split(b"=", 1)[1].strip()
hits = []
for root, dirs, files in os.walk(sys.argv[2]):
    if "node_modules" in root:
        continue
    for name in files:
        path = os.path.join(root, name)
        try:
            if os.path.islink(path) or os.path.getsize(path) > 50_000_000:
                continue
            if token and token in open(path, "rb").read():
                hits.append(path)
        except OSError:
            pass
print(f"control token occurrences in the agent account: {len(hits)}")
for path in hits:
    print("  " + path)
sys.exit(1 if hits else 0)
PY

  # The gateway under the agent account.
  sudo -u agent mkdir -p "$AGENT_HOME/.config/systemd/user"
  sed 's#/home/ubuntu#/home/agent#g' "$HOME/.config/systemd/user/openclaw-gateway.service" \
    | sudo -u agent tee "$AGENT_HOME/.config/systemd/user/openclaw-gateway.service" >/dev/null

  bash "$HERE/init_secrets.sh" install || [ $? -eq 2 ]
  as_agent systemctl --user daemon-reload
  as_agent systemctl --user enable -q openclaw-gateway.service
  as_agent bash "$AGENT_HOME/agents/_src/scripts/setup_agents.sh"
  as_agent bash "$AGENT_HOME/agents/_src/scripts/configure_models.sh"
  echo "== agent account"
  as_agent hermes --version | head -n 1
  as_agent openclaw --version
  as_agent openclaw config get agents.entries.backend.workspace
  as_agent systemctl --user is-active openclaw-gateway.service
}

case "${1:-}" in
  app) migrate_app;;
  agents) migrate_agents;;
  *) sed -n 2,8p "$0"; exit 2;;
esac

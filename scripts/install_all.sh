#!/usr/bin/env bash
# One-shot VM setup after `terraform apply`, run as `ubuntu`: accounts, credentials, runtimes, agent
# identities, models, the app, and the dispatcher left stopped until the owner approves it.
# First: scripts/init_secrets.sh prepare, then copy agents.env to ~/.secrets/agents.env.
# Re-runnable: every step is idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT_HOME=/home/agent
rc=0; bash "$HERE/init_secrets.sh" check || rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || exit "$rc"

bash "$HERE/install_gate.sh"
bash "$HERE/init_secrets.sh" install || [ $? -eq 2 ]

as_agent() {
  sudo -n -u agent -H env -i HOME="$AGENT_HOME" USER=agent LOGNAME=agent LANG=C.UTF-8 \
    XDG_RUNTIME_DIR="/run/user/$(id -u agent)" \
    PATH="$AGENT_HOME/.local/bin:$AGENT_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}
# The agents' copy of the scripts is theirs and has no authority. The control plane runs from ~/agents/_src
# under /home/ubuntu, which they cannot read.
as_agent mkdir -p "$AGENT_HOME/agents"
as_agent test -d "$AGENT_HOME/agents/_src/.git" \
  || as_agent git clone -q https://github.com/ambativachan8-cmyk/daily-briefing.git "$AGENT_HOME/agents/_src"
as_agent bash "$AGENT_HOME/agents/_src/scripts/vm_bootstrap.sh"
as_agent bash "$AGENT_HOME/agents/_src/scripts/setup_agents.sh"
as_agent bash "$AGENT_HOME/agents/_src/scripts/configure_models.sh"

bash "$HERE/deploy_app.sh"
bash "$HERE/install_dispatch_timer.sh"
bash "$HERE/init_secrets.sh" verify || true
echo "Setup finished. The dispatcher is on hold: see scripts/install_dispatch_timer.sh."

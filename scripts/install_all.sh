#!/usr/bin/env bash
# One-shot VM setup after `terraform apply`: runtimes, agent identities, models, dispatcher,
# and the app. Needs ~/.secrets/agents.env on the VM first (see agents/agents.env.example).
# Re-runnable: every step is idempotent.
set -euo pipefail
[ -f "$HOME/.secrets/agents.env" ] || { echo "copy agents.env to ~/.secrets/agents.env first" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/vm_bootstrap.sh"
bash "$HERE/setup_agents.sh"
bash "$HERE/configure_models.sh"
bash "$HERE/install_dispatch_timer.sh"
bash "$HERE/deploy_app.sh"

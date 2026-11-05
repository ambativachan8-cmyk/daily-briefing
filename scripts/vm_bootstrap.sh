#!/usr/bin/env bash
# Installs the two agent runtimes on the VM with their official install.sh scripts.
# Runs as the `agent` account, which has no sudo (see install_all.sh). cloud-init has installed git/gh/python.
# Re-runnable: both installers upgrade in place.
set -euo pipefail

mkdir -p ~/installers && cd ~/installers

echo "== OpenClaw"
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh -o openclaw-install.sh
bash openclaw-install.sh --no-onboard --no-prompt

echo "== Hermes Agent"
curl -fsSL --proto '=https' --tlsv1.2 https://hermes-agent.nousresearch.com/install.sh -o hermes-install.sh
bash hermes-install.sh --non-interactive --skip-browser --skip-computer-use

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
echo "== Versions"
openclaw --version || true
hermes --version || true

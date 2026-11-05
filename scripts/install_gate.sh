#!/usr/bin/env bash
# Creates the two unprivileged accounts the security boundary rests on. Idempotent. Run as `ubuntu`.
#
#   agent      runs OpenClaw and Hermes: no sudo, no adm/lxd, no access to /home/ubuntu
#   candidate  runs PR code inside the sandbox in verify_pr.sh: no home, no login, no credentials
#
# `ubuntu` stays the owner's admin account and the control plane. It holds the approvals, the receipts, the
# production app and the token that can publish gates. /home/ubuntu must stay closed to other users.
set -euo pipefail

getent passwd agent >/dev/null || sudo useradd --create-home --shell /bin/bash agent
getent passwd candidate >/dev/null || sudo useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin candidate

for account in agent candidate; do
  for group in sudo adm lxd docker; do
    if id -nG "$account" | tr ' ' '\n' | grep -qx "$group"; then sudo gpasswd -d "$account" "$group" >/dev/null; fi
  done
done
sudo loginctl enable-linger agent

# The runtime installers run as `agent`, without sudo, so anything they would apt-install comes first.
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -q nodejs >/dev/null
fi

sudo chmod 750 "$HOME"
sudo chmod 750 /home/agent
install -d -m 700 "$HOME/.secrets" "$HOME/control"
sudo install -d -o root -g root -m 755 /var/lib/candidate-gate

echo "agent:     $(id agent)"
echo "candidate: $(id candidate)"
echo "agent sudo rules: $(sudo -l -U agent 2>/dev/null | grep -c 'may run' || true)"

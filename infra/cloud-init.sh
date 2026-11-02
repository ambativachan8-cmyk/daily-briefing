#!/bin/bash
# First-boot setup: base packages and swap only. Agent runtimes are installed
# by scripts/vm_bootstrap.sh so the install is visible and re-runnable.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl jq sqlite3 python3 python3-venv python3-pip unzip ca-certificates

# GitHub CLI (official apt repo)
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y gh

# 4 GiB swap: two agent runtimes + the app on 8 GiB RAM
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

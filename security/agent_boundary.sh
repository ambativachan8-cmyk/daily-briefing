#!/usr/bin/env bash
# What the agent account can and cannot reach on the real host. Run as `ubuntu` after install_gate.sh.
# Every attempt really runs as the `agent` user. It prints outcomes only, never file contents.
#
#   security/agent_boundary.sh           the OS boundary
#   security/agent_boundary.sh --token   also the agent's GitHub token: no status can be set (changes nothing)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FAILS=0
A=(sudo -n -u agent -H env -i HOME=/home/agent PATH=/usr/local/bin:/usr/bin:/bin)
denied() {  # <label> <command...>: passes when the command fails as the agent user
  local label="$1"; shift
  if "${A[@]}" "$@" >/dev/null 2>&1; then echo "  FAILED  agent could: $label"; FAILS=$((FAILS + 1)); else echo "  PROVEN  agent cannot: $label"; fi
}
check() {  # <label> <condition command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  PROVEN  $label"; else echo "  FAILED  $label"; FAILS=$((FAILS + 1)); fi
}

echo "== positive controls: without these, a broken probe would make every denial below look proven"
check "probes really run as the agent user" test "$("${A[@]}" id -un 2>/dev/null)" = agent
check "the agent user can read its own home" "${A[@]}" test -r /home/agent
check "the owner can read what the agent is denied" test -r "$HOME/deploy/shared/data/briefing.db"

echo "== accounts"
check "agent belongs only to its own group" test "$(id -nG agent)" = agent
check "candidate belongs only to its own group" test "$(id -nG candidate)" = candidate
check "candidate has no login shell" test "$(getent passwd candidate | cut -d: -f7)" = /usr/sbin/nologin
check "/home/ubuntu is closed to other users" test "$(stat -c %a "$HOME")" = 750
denied "use sudo" sudo -n true
denied "switch to ubuntu with su" su -c true ubuntu

echo "== control plane"
denied "read the control secrets" cat "$HOME/.secrets/agents.env"
denied "read the control gh login" cat "$HOME/.config/gh/hosts.yml"
denied "list approvals" ls "$HOME/control/approvals"
denied "list receipts" ls "$HOME/control/receipts"
denied "write an approval" sh -c "echo forged > '$HOME/control/approvals/forged.json'"
denied "write a receipt" sh -c "echo forged > '$HOME/control/receipts/forged.json'"
denied "run the approval script" bash "$HOME/agents/_src/scripts/approve_candidate.sh" 1 0000000000000000000000000000000000000000
denied "run the verdict script" bash "$HOME/agents/_src/scripts/post_verdict.sh" test 1 1 0000000000000000000000000000000000000000 PASS /dev/null
denied "edit the dispatcher" sh -c "echo forged >> '$HOME/agents/_src/scripts/dispatch.sh'"

echo "== production"
denied "read the production database" cat "$HOME/deploy/shared/data/briefing.db"
denied "write into the production database directory" sh -c "echo x > '$HOME/deploy/shared/data/forged'"
denied "read host logs" cat "$HOME/logs/dispatch.log"
denied "change the serving release" ln -sfn /tmp "$HOME/deploy/current"
denied "stop the production service" systemctl --user -M ubuntu@ stop daily-briefing.service
denied "write to the sandbox's wheel directory" sh -c "echo x > /var/lib/candidate-gate/forged"

echo "== no AWS credentials on this host"
TOKEN="$(curl -s -m 3 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
check "the instance has no IAM role" test "$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)" = 404
check "no ~/.aws for ubuntu" test ! -e "$HOME/.aws"
denied "find ~/.aws" test -e /home/agent/.aws

echo "== the control token is not on the agent account"
if sudo python3 -I - "$HOME/.secrets/agents.env" /home/agent <<'PY'
import os, sys
token = b""
for line in open(sys.argv[1], "rb"):
    if line.startswith(b"GH_TOKEN="):
        token = line.split(b"=", 1)[1].strip()
if not token:
    sys.exit(2)
hits = 0
for root, dirs, files in os.walk(sys.argv[2]):
    if "node_modules" in root:
        continue
    for name in files:
        path = os.path.join(root, name)
        try:
            if not os.path.islink(path) and os.path.getsize(path) < 50_000_000 and token in open(path, "rb").read():
                hits += 1
        except OSError:
            pass
sys.exit(1 if hits else 0)
PY
then echo "  PROVEN  no file under /home/agent contains the control token"; else echo "  FAILED  control token found under /home/agent, or none configured"; FAILS=$((FAILS + 1)); fi

if [ "${1:-}" = "--token" ]; then
  echo "== the agent's GitHub token"
  bash "$HERE/../scripts/init_secrets.sh" verify || FAILS=$((FAILS + 1))
fi

echo
echo "agent boundary: $FAILS failed"
exit "$FAILS"

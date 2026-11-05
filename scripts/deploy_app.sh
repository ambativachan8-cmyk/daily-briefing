#!/usr/bin/env bash
# Deploys merged `main` on the VM: a clean checkout at ~/app (never an agent's clone), one
# uvicorn worker on loopback (the app's single in-process scheduler must not run twice),
# and Caddy on :80/:443 in front of it.
#
#   deploy_app.sh               install/refresh everything and (re)start the app
#   deploy_app.sh --if-changed  do nothing unless origin/main moved since the last deploy
set -euo pipefail
REPO_URL="https://github.com/ambativachan8-cmyk/daily-briefing.git"
APP="$HOME/app"; PORT=8000
IP="$(curl -s --max-time 5 -H "X-aws-ec2-metadata-token: $(curl -s -X PUT --max-time 5 \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)" \
  http://169.254.169.254/latest/meta-data/public-ipv4)"
HOST="${IP//./-}.sslip.io"

[ -d "$APP/.git" ] || git clone -q "$REPO_URL" "$APP"
git -C "$APP" fetch -q origin main
if [ "${1:-}" = "--if-changed" ] && [ "$(git -C "$APP" rev-parse HEAD)" = "$(git -C "$APP" rev-parse origin/main)" ] \
   && systemctl --user is-active -q daily-briefing.service; then
  exit 0
fi
# Docs, scripts and tests do not change the running app. A restart would add a run to the public
# history (the scheduler ticks at startup), so only move the checkout.
if [ "${1:-}" = "--if-changed" ] && systemctl --user is-active -q daily-briefing.service \
   && git -C "$APP" diff --quiet HEAD origin/main -- app templates requirements.txt; then
  git -C "$APP" checkout -q --detach origin/main
  exit 0
fi
git -C "$APP" checkout -q --detach origin/main
[ -f "$APP/requirements.txt" ] && [ -f "$APP/app/main.py" ] || { echo "main has no app yet; nothing to deploy"; exit 0; }

python3 -m venv "$APP/.venv"
"$APP/.venv/bin/pip" install -q --upgrade pip
"$APP/.venv/bin/pip" install -q -r "$APP/requirements.txt"

D="$HOME/.config/systemd/user"; mkdir -p "$D"
cat > "$D/daily-briefing.service" <<EOF
[Unit]
Description=Daily Briefing web app (merged main)

[Service]
WorkingDirectory=$APP
# The synthetic feed gains one item every 6 hours, so each scheduled run has something new to report.
Environment=SCHEDULER_INTERVAL_SECONDS=21600
ExecStart=$APP/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $PORT --workers 1
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable -q daily-briefing.service
systemctl --user restart daily-briefing.service

# Caddy from its official apt repository (free, open source); TLS via Let's Encrypt for the
# sslip.io name, plain HTTP on the bare IP as a fallback.
if ! command -v caddy >/dev/null; then
  sudo apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -q >/dev/null && sudo apt-get install -y -q caddy >/dev/null
fi
sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
$HOST {
	reverse_proxy 127.0.0.1:$PORT
}

http://$IP {
	reverse_proxy 127.0.0.1:$PORT
}
EOF
sudo systemctl reload caddy || sudo systemctl restart caddy

for i in $(seq 1 20); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
echo "deployed $(git -C "$APP" rev-parse --short HEAD): https://$HOST  (fallback http://$IP)"
curl -fsS "http://127.0.0.1:$PORT/health"; echo

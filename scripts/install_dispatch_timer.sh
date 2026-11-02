#!/usr/bin/env bash
# Runs `dispatch.sh next` every 10 minutes as a systemd user timer on the VM, so the agent
# team keeps moving without a human starting each run. Overlap is impossible (flock in
# dispatch.sh); quota pauses and the loop guard stop it from burning free quota.
#   install_dispatch_timer.sh            install + start
#   systemctl --user stop dispatch.timer  pause the team
set -euo pipefail
D="$HOME/.config/systemd/user"; mkdir -p "$D"
cat > "$D/dispatch.service" <<EOF
[Unit]
Description=Daily Briefing agent team: route and run the next ticket

[Service]
Type=oneshot
Environment=PATH=$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
# Continuous deployment: redeploy merged main before routing the next ticket ("-" = a failed
# deploy never stops the team; the previous build keeps serving).
ExecStartPre=-/bin/bash $HOME/agents/_src/scripts/deploy_app.sh --if-changed
ExecStart=/bin/bash $HOME/agents/_src/scripts/dispatch.sh next
StandardOutput=append:$HOME/logs/dispatch.log
StandardError=append:$HOME/logs/dispatch.log
TimeoutStartSec=3h
EOF
cat > "$D/dispatch.timer" <<'EOF'
[Unit]
Description=Run the agent dispatcher every 10 minutes

[Timer]
OnCalendar=*:0/10
Persistent=false

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now dispatch.timer
systemctl --user list-timers dispatch.timer --no-pager

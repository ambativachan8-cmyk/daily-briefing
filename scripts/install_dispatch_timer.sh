#!/usr/bin/env bash
# Installs the systemd user units that run `dispatch.sh next` every 2 minutes. Automation is opt-in: this
# leaves the dispatcher stopped behind a hold file until the owner decides to start it.
#
#   install_dispatch_timer.sh           write the service; set the hold if none exists; start nothing
#   install_dispatch_timer.sh --enable  start the timer. Refuses while the hold file exists: the owner removes
#                                       ~/.config/dispatch-security-hold first, as the explicit approval
#   systemctl --user stop dispatch.timer  pause the team
set -euo pipefail
D="$HOME/.config/systemd/user"; mkdir -p "$D"
HOLD="$HOME/.config/dispatch-security-hold"

cat > "$D/dispatch.service" <<EOF
[Unit]
Description=Daily Briefing agent team: route and run the next ticket
ConditionPathExists=!$HOLD

[Service]
Type=oneshot
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
# Continuous deployment: redeploy merged main before routing the next ticket. A failed deploy leaves the
# current release serving and is retried on the next tick ("-" = it never stops the team).
ExecStartPre=-/bin/bash $HOME/agents/_src/scripts/deploy_app.sh --if-changed
ExecStart=/bin/bash $HOME/agents/_src/scripts/dispatch.sh next
StandardOutput=append:$HOME/logs/dispatch.log
StandardError=append:$HOME/logs/dispatch.log
TimeoutStartSec=3h
EOF

if [ "${1:-}" != "--enable" ]; then
  [ -e "$HOLD" ] || echo "hold set $(date -u +%FT%TZ): automation stays off until the owner approves it" > "$HOLD"
  systemctl --user daemon-reload
  echo "dispatch.service installed. Hold in place: $HOLD. Nothing was started."
  exit 0
fi

[ ! -e "$HOLD" ] || { echo "REFUSED: $HOLD exists. Removing it is the owner's approval to run the agents." >&2; exit 3; }
# The boundary must really be in place. The agents' token must not be able to set the gates, and the control
# plane must run merged code: dispatch.sh updates itself with `git pull`, which needs a branch, not a pinned commit.
SRC="$HOME/agents/_src"
bash "$(cd "$(dirname "$0")" && pwd)/init_secrets.sh" verify || { echo "REFUSED: fix the tokens first." >&2; exit 3; }
git -C "$SRC" fetch -q origin main
git -C "$SRC" cat-file -e origin/main:scripts/gate_lib.sh 2>/dev/null || { echo "REFUSED: the security fix is not on main yet." >&2; exit 3; }
git -C "$SRC" checkout -q main
git -C "$SRC" pull -q --ff-only
sudo -n -u agent -H git -C /home/agent/agents/_src fetch -q origin main
sudo -n -u agent -H git -C /home/agent/agents/_src checkout -q main
sudo -n -u agent -H git -C /home/agent/agents/_src pull -q --ff-only
rm -f "$D/dispatch.timer"   # also clears a mask, which is a symlink at this path
cat > "$D/dispatch.timer" <<'EOF'
[Unit]
Description=Run the agent dispatcher every 2 minutes

[Timer]
OnCalendar=*:0/2
Persistent=false

[Install]
WantedBy=timers.target
EOF
rm -rf "$D/dispatch.service.d"
systemctl --user daemon-reload
systemctl --user enable --now dispatch.timer
systemctl --user list-timers dispatch.timer --no-pager

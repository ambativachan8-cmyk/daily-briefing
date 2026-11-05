#!/usr/bin/env bash
# Deploys merged `main` on the VM with a staged release: the build and its startup check never touch what is
# serving, and the deployed SHA is recorded only after the live service is healthy on the new release.
#
#   deploy_app.sh                install/refresh everything and deploy origin/main
#   deploy_app.sh --if-changed   deploy only if the app changed since the deployed SHA (the dispatcher's call)
#   deploy_app.sh --rollback     return to the previous known-good release, and keep main's head from redeploying
#   deploy_app.sh --status       print the deployed and previous SHAs
#
# Layout under $DEPLOY_ROOT (default ~/deploy):
#   repo.git            bare mirror of the repository
#   releases/<sha>/     one export and its own virtualenv; `.ready` once it has passed the startup check
#   current             symlink to the serving release, replaced atomically
#   shared/data/        the database, linked into every release
#   shared/backups/     a database copy taken before each swap
#   state/deployed_sha  written only after a verified start
#   state/previous_sha  the release to roll back to
#   state/held_sha      a head that failed on the live service or was rolled back: not retried automatically
#
# A failed build or startup check leaves the old release serving and is retried on the next call.
set -euo pipefail

REPO_URL="${DEPLOY_REPO_URL:-https://github.com/ambativachan8-cmyk/daily-briefing.git}"
ROOT="${DEPLOY_ROOT:-$HOME/deploy}"
SERVICE="${DEPLOY_SERVICE:-daily-briefing}"
PORT="${DEPLOY_PORT:-8000}"
STAGE_PORT="${DEPLOY_STAGE_PORT:-18001}"
MANAGE_CADDY="${DEPLOY_MANAGE_CADDY:-yes}"
INTERVAL="${SCHEDULER_INTERVAL_SECONDS:-21600}"   # the synthetic feed gains one item every 6 hours

STATE="$ROOT/state"; RELEASES="$ROOT/releases"; MIRROR="$ROOT/repo.git"
mkdir -p "$STATE" "$RELEASES" "$ROOT/shared/data" "$ROOT/shared/backups"
exec 7>"$STATE/deploy.lock"; flock 7

log() { echo "deploy: $*"; }
read_state() { cat "$STATE/$1" 2>/dev/null || true; }
write_state() { printf '%s\n' "$2" > "$STATE/$1.tmp"; mv -f "$STATE/$1.tmp" "$STATE/$1"; }
service_active() { systemctl --user is-active -q "$SERVICE.service"; }
page_ok() {  # <port>: /health answers 200 and / is an HTML page
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/health")" = 200 ] \
    && curl -s -m 5 "http://127.0.0.1:$1/" | grep -qi '<html'
}
wait_healthy() {  # <port> <seconds>
  local i
  for i in $(seq 1 "$2"); do page_ok "$1" && return 0; sleep 1; done
  return 1
}

install_unit() {
  local d="$HOME/.config/systemd/user"; mkdir -p "$d"
  cat > "$d/$SERVICE.service" <<EOF
[Unit]
Description=Daily Briefing web app (merged main, staged release)

[Service]
WorkingDirectory=$ROOT/current
Environment=SCHEDULER_INTERVAL_SECONDS=$INTERVAL
ExecStart=$ROOT/current/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $PORT --workers 1
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable -q "$SERVICE.service"
}

# Builds the release beside the serving one and starts it on its own port with an empty, throwaway database.
stage() {  # <sha>
  local sha="$1" dir="$RELEASES/$1" pid rc=0
  if [ -e "$dir/.ready" ]; then log "release ${sha:0:7} is already staged"; return 0; fi
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$MIRROR" archive --format=tar "$sha" | tar -x -C "$dir"
  [ -f "$dir/requirements.txt" ] && [ -f "$dir/app/main.py" ] || { log "$sha has no app to deploy"; rm -rf "$dir"; return 1; }
  # A release's data/ is the production database, and the test suite empties the database it finds.
  rm -rf "$dir/tests"
  python3 -m venv "$dir/.venv"
  if ! "$dir/.venv/bin/pip" install -q -r "$dir/requirements.txt"; then
    log "dependency install failed for ${sha:0:7}; nothing changed, the current release keeps serving"
    rm -rf "$dir"; return 1
  fi
  ( cd "$dir" && exec "$dir/.venv/bin/uvicorn" app.main:app --host 127.0.0.1 --port "$STAGE_PORT" --log-level warning ) >"$STATE/stage.log" 2>&1 &
  pid=$!
  wait_healthy "$STAGE_PORT" 30 || rc=1
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    log "startup check failed for ${sha:0:7}; nothing changed, the current release keeps serving"
    tail -n 5 "$STATE/stage.log" || true
    rm -rf "$dir"; return 1
  fi
  rm -rf "$dir/data"; ln -s "$ROOT/shared/data" "$dir/data"
  : > "$dir/.ready"
  log "staged and checked ${sha:0:7}"
}

point_current_at() {  # <sha>
  ln -sfn "$RELEASES/$1" "$ROOT/current.tmp"
  mv -Tf "$ROOT/current.tmp" "$ROOT/current"
}

backup_db() {
  local db="$ROOT/shared/data/briefing.db"
  [ -f "$db" ] || return 0
  sqlite3 "$db" ".backup '$ROOT/shared/backups/before-$1.db'"
  ls -1t "$ROOT/shared/backups"/before-*.db | tail -n +4 | xargs -r rm -f
}

prune() {  # keep the serving release, the rollback target and one more
  local keep; keep="$(read_state deployed_sha) $(read_state previous_sha)"
  local dir n=0
  for dir in $(ls -1dt "$RELEASES"/* 2>/dev/null); do
    case " $keep " in *" $(basename "$dir") "*) continue;; esac
    n=$((n + 1)); [ "$n" -le 1 ] || rm -rf "$dir"
  done
}

# Swap, restart, verify. On failure the old release comes back and the head is held, so a bad release cannot
# take the public service down again on every tick.
activate() {  # <sha>
  local sha="$1" old; old="$(read_state deployed_sha)"
  backup_db "$sha"
  install_unit
  point_current_at "$sha"
  systemctl --user restart "$SERVICE.service"
  if wait_healthy "$PORT" 30; then
    [ -z "$old" ] || [ "$old" = "$sha" ] || write_state previous_sha "$old"
    write_state deployed_sha "$sha"
    rm -f "$STATE/held_sha"
    log "serving ${sha:0:7}; recorded as deployed"
    return 0
  fi
  log "${sha:0:7} failed on the live service"
  write_state held_sha "$sha"
  if [ -n "$old" ] && [ -e "$RELEASES/$old/.ready" ]; then
    point_current_at "$old"
    systemctl --user restart "$SERVICE.service"
    wait_healthy "$PORT" 30 && log "restored ${old:0:7}" || log "ATTENTION: restore of ${old:0:7} did not become healthy"
  fi
  return 1
}

rollback() {
  local target cur; target="$(read_state previous_sha)"; cur="$(read_state deployed_sha)"
  [ -n "$target" ] && [ -e "$RELEASES/$target/.ready" ] || { log "no known-good previous release"; return 1; }
  point_current_at "$target"
  systemctl --user restart "$SERVICE.service"
  wait_healthy "$PORT" 30 || { log "ATTENTION: rollback target ${target:0:7} did not become healthy"; return 1; }
  write_state deployed_sha "$target"
  write_state previous_sha "$cur"
  write_state held_sha "$cur"
  log "rolled back to ${target:0:7}; ${cur:0:7} stays held until a newer commit or an explicit deploy"
}

configure_caddy() {
  [ "$MANAGE_CADDY" = yes ] || return 0
  local ip host want
  ip="$(curl -s --max-time 5 -H "X-aws-ec2-metadata-token: $(curl -s -X PUT --max-time 5 \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)" \
    http://169.254.169.254/latest/meta-data/public-ipv4)"
  host="${ip//./-}.sslip.io"
  # Caddy from its official apt repository (free, open source); TLS via Let's Encrypt for the sslip.io name,
  # plain HTTP on the bare IP as a fallback.
  if ! command -v caddy >/dev/null; then
    sudo apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -q >/dev/null && sudo apt-get install -y -q caddy >/dev/null
  fi
  want="$(printf '%s {\n\treverse_proxy 127.0.0.1:%s\n}\n\nhttp://%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' "$host" "$PORT" "$ip" "$PORT")"
  if [ "$(cat /etc/caddy/Caddyfile 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" | sudo tee /etc/caddy/Caddyfile >/dev/null
    sudo systemctl reload caddy || sudo systemctl restart caddy
  fi
  log "public URL https://$host (fallback http://$ip)"
}

case "${1:-}" in
  --status)
    echo "deployed=$(read_state deployed_sha) previous=$(read_state previous_sha) held=$(read_state held_sha) current=$(basename "$(readlink "$ROOT/current" 2>/dev/null || echo none)")"
    exit 0;;
  --rollback) rollback; exit $?;;
  --stage-only) stage "$2"; exit $?;;        # used once by migrate_existing_vm.sh
  --activate-only) activate "$2"; exit $?;;  # used once by migrate_existing_vm.sh
esac

[ -d "$MIRROR" ] || git init -q --bare "$MIRROR"
git -C "$MIRROR" fetch -q --force "$REPO_URL" "+refs/heads/main:refs/heads/main"
TARGET="$(git -C "$MIRROR" rev-parse refs/heads/main)"
DEPLOYED="$(read_state deployed_sha)"

if [ "${1:-}" = "--if-changed" ]; then
  if [ "$TARGET" = "$(read_state held_sha)" ]; then log "${TARGET:0:7} is held; run an explicit deploy to retry it"; exit 0; fi
  if [ "$TARGET" = "$DEPLOYED" ] && service_active; then exit 0; fi
  # Docs, scripts and tests do not change the running app. A restart would add a run to the public history
  # (the scheduler ticks at startup), so the deployed SHA stays what is really serving.
  if [ -n "$DEPLOYED" ] && service_active \
     && git -C "$MIRROR" diff --quiet "$DEPLOYED" "$TARGET" -- app templates requirements.txt; then
    exit 0
  fi
fi

stage "$TARGET" || exit 1
activate "$TARGET" || exit 1
prune
configure_caddy
curl -fsS "http://127.0.0.1:$PORT/health"; echo

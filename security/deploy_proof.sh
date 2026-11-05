#!/usr/bin/env bash
# Deployment proof on a disposable service and port. Never touches the public app.
#
#   security/deploy_proof.sh baseline    the audited deploy script against a dependency failure
#   security/deploy_proof.sh fixed       staged deploy: failure, old release serving, retry, bad start, rollback
#
# Needs: a clone of this repository (the audited commit's product tree is the test app), pip reaching PyPI.
set -uo pipefail
MODE="${1:?usage: deploy_proof.sh baseline|fixed}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
BASELINE=e2a83ce6cf4190091dbc7bdb91434730b4d29084
W="$HOME/security-sim/deploy-$MODE-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$W"; REMOTE="$W/remote.git"; SEED="$W/seed"
FAILS=0
pass() { echo "  PROVEN  $*"; }
fail() { echo "  FAILED  $*"; FAILS=$((FAILS + 1)); }
commit() { git -C "$SEED" add -A; git -C "$SEED" -c user.name=fixture -c user.email=f@x.invalid commit -q --allow-empty -m "$1"; git -C "$SEED" push -q origin main; git -C "$SEED" rev-parse HEAD; }

git init -q --bare -b main "$REMOTE"
git clone -q "$REMOTE" "$SEED" 2>/dev/null
git -C "$ROOT" archive "$BASELINE" app templates requirements.txt | tar -x -C "$SEED"
git -C "$SEED" checkout -q -b main 2>/dev/null
GOOD1="$(commit 'good release one')"
GOOD_REQS="$(cat "$SEED/requirements.txt")"

if [ "$MODE" = baseline ]; then
  # The audited script, in a fake HOME, with systemctl/sudo/curl stubbed so that it cannot reach the real
  # service or Caddy. It stops at the failure anyway; the stubs guarantee that even if it did not.
  H="$W/home"; mkdir -p "$H/bin" "$H/old"
  git -C "$ROOT" show "$BASELINE:scripts/deploy_app.sh" > "$H/old/deploy_app.sh"
  printf '#!/bin/sh\nexit 0\n' > "$H/bin/systemctl"; printf '#!/bin/sh\nexit 0\n' > "$H/bin/sudo"; printf '#!/bin/sh\nexit 0\n' > "$H/bin/curl"
  printf '#!/bin/sh\nexit 0\n' > "$H/bin/caddy"; chmod +x "$H/bin"/*
  cat > "$H/.gitconfig" <<EOF
[url "file://$REMOTE"]
	insteadOf = https://github.com/ambativachan8-cmyk/daily-briefing.git
[protocol "file"]
	allow = always
EOF
  run_old() { env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" bash "$H/old/deploy_app.sh" "$@"; }
  echo "== first deploy of a good release"
  run_old >/dev/null 2>&1; echo "  exit $?"
  echo "== main moves to a release with an uninstallable dependency"
  printf 'this-package-does-not-exist-confer==9.9.9\n' >> "$SEED/requirements.txt"
  BAD="$(commit 'bad dependency')"
  run_old --if-changed >"$W/old1.log" 2>&1; rc1=$?
  echo "  --if-changed exit $rc1"
  HEAD_AFTER="$(git -C "$H/app" rev-parse HEAD)"
  [ "$HEAD_AFTER" = "$BAD" ] && echo "  REPRODUCED the serving checkout moved to the bad commit before the install failed"
  grep -q this-package-does-not-exist "$H/app/requirements.txt" && echo "  REPRODUCED the serving tree now holds the bad code; any restart would run it on the old virtualenv"
  run_old --if-changed >"$W/old2.log" 2>&1; rc2=$?
  echo "  second --if-changed exit $rc2"
  [ "$rc2" = 0 ] && ! grep -qi 'error\|No matching' "$W/old2.log" && echo "  REPRODUCED the retry did nothing: HEAD already equals main, so the failed deploy counts as done"
  echo "baseline proof finished; files in $W"
  exit 0
fi

export DEPLOY_ROOT="$W/deploy" DEPLOY_REPO_URL="file://$REMOTE" DEPLOY_SERVICE=dbproof DEPLOY_PORT=18090 DEPLOY_STAGE_PORT=18091 DEPLOY_MANAGE_CADDY=no
export GIT_ALLOW_PROTOCOL=file
DEPLOY="$ROOT/scripts/deploy_app.sh"
U="http://127.0.0.1:$DEPLOY_PORT"
cleanup() { systemctl --user disable --now dbproof.service 2>/dev/null; rm -f "$HOME/.config/systemd/user/dbproof.service"; systemctl --user daemon-reload; [ -n "${WATCH:-}" ] && kill "$WATCH" 2>/dev/null; }
trap cleanup EXIT
serving() { basename "$(readlink -f "/proc/$(systemctl --user show -p MainPID --value dbproof.service)/cwd")"; }
main_pid() { systemctl --user show -p MainPID --value dbproof.service; }
state() { cat "$DEPLOY_ROOT/state/$1" 2>/dev/null; }

echo "== 1. first deploy"
bash "$DEPLOY" >"$W/d1.log" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(state deployed_sha)" = "$GOOD1" ] && [ "$(serving)" = "$GOOD1" ] && pass "good release ${GOOD1:0:7} serving and recorded" || fail "first deploy rc=$rc"

# Seed state that must survive every release.
curl -s -o /dev/null -X POST "$U/ingest"
RUNS="$(curl -s "$U/runs" | jq '.runs | length')"
echo "  runs in the shared database: $RUNS"

echo "== 2. a release whose dependency cannot be installed"
printf 'this-package-does-not-exist-confer==9.9.9\n' >> "$SEED/requirements.txt"
BAD="$(commit 'bad dependency')"
PID_BEFORE="$(main_pid)"
( while :; do curl -s -m 2 -o /dev/null -w '%{http_code}\n' "$U/health"; sleep 0.2; done ) > "$W/availability.log" 2>&1 &
WATCH=$!
bash "$DEPLOY" --if-changed >"$W/d2.log" 2>&1; rc=$?
kill "$WATCH" 2>/dev/null; WATCH=""
TOTAL="$(wc -l < "$W/availability.log")"; NOT200="$(grep -vc '^200$' "$W/availability.log")"
tail -n 1 "$W/d2.log" | sed 's/^/  /'
[ "$rc" != 0 ] && pass "deploy reported failure (exit $rc)" || fail "deploy returned 0 on a broken dependency"
[ "$NOT200" = 0 ] && [ "$TOTAL" -gt 5 ] && pass "old release served throughout: $TOTAL health checks, $NOT200 not 200" || fail "availability: $NOT200 of $TOTAL not 200"
[ "$(main_pid)" = "$PID_BEFORE" ] && pass "serving process untouched (pid $PID_BEFORE)" || fail "serving process changed"
[ "$(state deployed_sha)" = "$GOOD1" ] && [ "$(serving)" = "$GOOD1" ] && pass "deployed SHA still ${GOOD1:0:7}; bad ${BAD:0:7} not recorded" || fail "deployed SHA moved"
[ ! -e "$DEPLOY_ROOT/releases/$BAD" ] && pass "failed release removed from releases/" || fail "failed release left behind"

echo "== 3. retry: the next call tries again, and a fix deploys"
bash "$DEPLOY" --if-changed >"$W/d3.log" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'dependency install failed' "$W/d3.log" && pass "the retry really attempted the install again" || fail "retry did not run (rc=$rc)"
printf '%s\n' "$GOOD_REQS" > "$SEED/requirements.txt"
echo "# release two" >> "$SEED/app/__init__.py"
GOOD2="$(commit 'fixed dependency')"
bash "$DEPLOY" --if-changed >"$W/d4.log" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(state deployed_sha)" = "$GOOD2" ] && [ "$(serving)" = "$GOOD2" ] && [ "$(state previous_sha)" = "$GOOD1" ] \
  && pass "fixed release ${GOOD2:0:7} deployed; previous recorded as ${GOOD1:0:7}" || fail "fixed deploy rc=$rc"
[ "$(curl -s "$U/runs" | jq '.runs | length')" -ge "$RUNS" ] && pass "shared database survived the release" || fail "database lost across releases"

echo "== 4. rollback"
bash "$DEPLOY" --rollback >"$W/d5.log" 2>&1; rc=$?
tail -n 1 "$W/d5.log" | sed 's/^/  /'
[ "$rc" = 0 ] && [ "$(serving)" = "$GOOD1" ] && [ "$(state deployed_sha)" = "$GOOD1" ] && pass "rolled back: ${GOOD1:0:7} serving and recorded" || fail "rollback rc=$rc"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/health")" = 200 ] && pass "healthy after rollback" || fail "unhealthy after rollback"
bash "$DEPLOY" --if-changed >"$W/d6.log" 2>&1
[ "$(serving)" = "$GOOD1" ] && grep -q 'is held' "$W/d6.log" && pass "the rolled-back head is not redeployed automatically" || fail "rolled-back head redeployed"

echo "== 5. a release that installs and passes staging, then fails only on the live service"
bash "$DEPLOY" >"$W/d7.log" 2>&1   # an explicit deploy clears the hold on ${GOOD2}
[ "$(serving)" = "$GOOD2" ] && pass "explicit deploy returned to ${GOOD2:0:7}" || fail "explicit deploy"
cat >> "$SEED/app/main.py" <<'EOF'

import os as _proof_os
if _proof_os.environ.get("SCHEDULER_INTERVAL_SECONDS"):  # set only on the live unit, not in staging
    raise RuntimeError("fails only under the live unit")
EOF
BADLIVE="$(commit 'fails only live')"
bash "$DEPLOY" --if-changed >"$W/d8.log" 2>&1; rc=$?
tail -n 2 "$W/d8.log" | sed 's/^/  /'
[ "$rc" != 0 ] && [ "$(serving)" = "$GOOD2" ] && [ "$(state deployed_sha)" = "$GOOD2" ] && pass "automatic restore: ${GOOD2:0:7} serving, ${BADLIVE:0:7} not recorded" || fail "automatic restore rc=$rc serving=$(serving)"
[ "$(state held_sha)" = "$BADLIVE" ] && pass "failing head is held, so it cannot flap the service each tick" || fail "failing head not held"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/health")" = 200 ] && pass "healthy after the automatic restore" || fail "unhealthy after restore"

echo
echo "deploy proof: $FAILS failed. Files in $W"
exit "$FAILS"

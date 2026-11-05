#!/usr/bin/env bash
# Deterministic evidence for one PR: fresh clone at the exact head, fresh virtualenv, full test
# suite, then the real app over HTTP. Real output only, so the agent reads it instead of spending
# model calls on setup, and cannot retype a result. The tester and reviewer still give the verdict.
#
#   verify_pr.sh <pr>     exit 0 = tests passed and the app answered /health
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
REPO="ambativachan8-cmyk/daily-briefing"
PR="${1:?usage: verify_pr.sh <pr>}"
SHA="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid)"
PORT=$(( 18000 + PR ))
W="$(mktemp -d)"; APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

echo "verify_pr head: $SHA"
git clone -q "https://github.com/$REPO.git" "$W/src" && cd "$W/src" || exit 2
git fetch -q origin "pull/$PR/head" && git checkout -q --detach "$SHA" || exit 2
echo "\$ git status --porcelain"; git status --porcelain; echo "(end of status)"
python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt 2>&1 | grep -v notice

echo; echo "\$ pytest -q"
SCHEDULER_ENABLED=false .venv/bin/python -m pytest -q -p no:cacheprovider 2>&1 | tail -n 25
TEST_RC="${PIPESTATUS[0]}"
echo "pytest exit code: $TEST_RC"
rm -rf data   # the app below starts on an empty database

echo; echo "\$ uvicorn app.main:app --port $PORT  (empty database, default scheduler settings)"
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level warning >"$W/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 20); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 1; done

call() {  # <method> <path>
  echo; echo "\$ curl -X $1 $2"
  curl -s --max-time 20 -X "$1" -w '\n[HTTP %{http_code}]\n' "http://127.0.0.1:$PORT$2" | cut -c1-1500 | head -n 60
}
call GET /health; HEALTH="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")"
call GET /runs
call POST /ingest
call POST /ingest
call GET /runs
call GET /
echo; echo "app log (last 15 lines):"; tail -n 15 "$W/app.log" | cut -c1-300

echo; echo "verify_pr result: pytest=$TEST_RC health=$HEALTH head=$SHA"
[ "$TEST_RC" = 0 ] && [ "$HEALTH" = 200 ]

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
# One real run per commit: the dispatcher, reviewer and tester all read the same output.
CACHE="$HOME/logs/verify/$SHA-$(md5sum "$0" | cut -c1-8).txt"
if [ -z "${VERIFY_PR_INNER:-}" ]; then
  mkdir -p "$(dirname "$CACHE")"
  if [ ! -s "$CACHE" ]; then
    VERIFY_PR_INNER=1 bash "$0" "$PR" > "$CACHE.tmp" 2>&1
    mv "$CACHE.tmp" "$CACHE"
  fi
  cat "$CACHE"
  grep -qE "^verify_pr result: pytest=0 health=200 page=(ok|n/a) " "$CACHE"
  exit $?
fi
# A free port: a fixed one could reach a process left over from an earlier run and test the wrong app.
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
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
# Make sure a first run exists (a scheduler tick may already have made it).
[ "$(curl -s "http://127.0.0.1:$PORT/runs" | jq '.runs | length' 2>/dev/null)" = 0 ] && call POST /ingest

# The brief's public page, judged on the raw HTML a first visitor receives: JavaScript that
# might fill the page later does not count. Skipped only while / is not an HTML page yet.
PAGE_RESULT=ok
page_check() {  # <label> <pattern> <text>
  if grep -qiE "$2" <<<"$3"; then echo "  ok      $1"; else echo "  MISSING $1"; PAGE_RESULT=fail; fi
}
FIRST="$(curl -s "http://127.0.0.1:$PORT/")"
if grep -qi '<html' <<<"$FIRST"; then
  echo; echo "Page checks on raw HTML after the first run:"
  page_check "a link for each new item" 'href="https://example\.com/item-[0-9]+"' "$FIRST"
  page_check "says this is the first run" 'first run' "$FIRST"
  page_check "dated briefing" '20[0-9]{2}-[0-9]{2}-[0-9]{2}|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* [0-9]{1,2}' "$FIRST"
  page_check "count of new items" '[0-9]+ new' "$FIRST"
  page_check "history row marked with a check mark" '✓|&check;|&#10003;|&#x2713;' "$FIRST"
  page_check "Run now control" 'run now' "$FIRST"
  grep -qiE 'fetch\(|XMLHttpRequest' <<<"$FIRST" && echo "  note    the page uses JavaScript to load data"

  # Use Run now the way a visitor does: post the page's own form, then read the page again.
  U="http://127.0.0.1:$PORT"
  runs_count() { curl -s "$U/runs" | jq '.runs | length'; }
  first_status() { curl -s "$U/runs" | jq -r '.runs[0].status'; }
  expect() {  # <label> <actual> <wanted>
    if [ "$2" = "$3" ]; then echo "  ok      $1"; else echo "  MISSING $1 (got $2, wanted $3)"; PAGE_RESULT=fail; fi
  }
  ACTION="$(grep -oiE 'action="[^"]+"' <<<"$FIRST" | head -n 1 | cut -d'"' -f2)"
  echo; echo "Run now, through the page's form (action=${ACTION:-none}):"
  if [ -z "$ACTION" ]; then
    echo "  MISSING a form that posts Run now"; PAGE_RESULT=fail
  else
    before="$(runs_count)"
    landed="$(curl -s -L -X POST "$U$ACTION")"
    expect "Run now adds one history row" "$(runs_count)" "$(( before + 1 ))"
    page_check "Run now returns to the page" '<html' "$landed"
    page_check "a run with nothing new says so" '0 new|no new|nothing new' "$(curl -s "$U/")"
    before="$(runs_count)"
    second="$(curl -s -L -X POST "$U$ACTION")"
    expect "an immediate second Run now adds no row" "$(runs_count)" "$before"
    page_check "the limited attempt stays on the page" '<html' "$second"
    page_check "the limited attempt tells the user" 'try again|rate.?limit|wait|too (soon|many)|busy' "$second"
    curl -s -o /dev/null -X POST "$U/ingest"
    expect "POST /ingest is no way around the limit" "$(runs_count)" "$before"
    sleep 10
    curl -s -L -o /dev/null -X POST "$U$ACTION"
    expect "the limit is a minute: a retry after 10 s adds no row" "$(runs_count)" "$before"
    echo "  (waiting out the 1-minute limit for the failure and recovery checks)"
    sleep 52
    .venv/bin/python -m app.ops fail-next >/dev/null
    curl -s -L -o /dev/null -X POST "$U$ACTION"
    expect "a failed fetch is stored as a failed run" "$(first_status)" failed
    page_check "the failed run shows a cross" '✗|&cross;|&#10007;|&#x2717;' "$(curl -s "$U/")"
    sleep 61
    curl -s -L -o /dev/null -X POST "$U$ACTION"
    expect "the next good run succeeds" "$(first_status)" success
  fi

  # The brief's core: only what is new. Restart on a controlled feed, so each start's scheduler tick
  # is one run, and count the new-item links in the latest briefing.
  echo; echo "What is new, by item links on the page (A1 to A5):"
  feed_run() {  # <label> <item numbers, comma-separated> <wanted links>
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
    FEED_ITEMS_JSON="$(python3 -c 'import json, sys; print(json.dumps([{"id": f"item-{i}", "title": f"Item {i}", "link": f"https://example.com/item-{i}"} for i in sys.argv[1].split(",")]))' "$2")" \
      .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level warning >>"$W/app.log" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 20); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 1; done
    sleep 1
    expect "$1" "$(curl -s "$U/" | grep -oE 'href="https://example\.com/item-[0-9]+"' | wc -l)" "$3"
  }
  kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; rm -rf data; APP_PID=""
  feed_run "A1 first run on 3 items shows 3" 1,2,3 3
  feed_run "A2 same feed shows 0" 1,2,3 0
  feed_run "A3 different order shows 0" 3,1,2 0
  feed_run "A4 one item added shows exactly 1" 1,2,3,4 1
  feed_run "item removed shows 0" 2,3,4 0
  feed_run "A5 removed item coming back shows 0" 1,2,3,4 0
else
  PAGE_RESULT=n/a; echo; echo "Page checks skipped: / is not an HTML page yet."
fi

call POST /ingest
call POST /ingest
call GET /runs
call GET /
echo; echo "app log (last 15 lines):"; tail -n 15 "$W/app.log" | cut -c1-300

echo; echo "verify_pr result: pytest=$TEST_RC health=$HEALTH page=$PAGE_RESULT head=$SHA"
[ "$TEST_RC" = 0 ] && [ "$HEALTH" = 200 ] && [ "$PAGE_RESULT" != fail ]

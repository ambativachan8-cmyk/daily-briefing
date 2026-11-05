#!/usr/bin/env bash
# Trusted runner for one owner-approved PR revision. All candidate code (tests, dependencies, app) runs
# as the `candidate` user in a transient systemd sandbox with a private network and no view of /home.
# This script, outside the sandbox, decides the result from exit statuses and from HTTP responses it
# fetches itself. It never searches candidate output for a result.
#
#   verify_pr.sh <pr>    exit 0 = PASS receipt for the approved head; 1 = FAIL receipt; 3 = refused, nothing ran
#
# Output: $CONTROL/transcripts/<sha>.txt (evidence for people and agents) and $CONTROL/receipts/<sha>.json.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
unset GH_TOKEN
. "$(cd "$(dirname "$0")" && pwd)/gate_lib.sh"
PR="${1:?usage: verify_pr.sh <pr>}"
gate_dirs

# Execution-time authorization: nothing below runs without it.
SHA="$(authorize_candidate "$PR")" || exit 3

# One real run per approved head and runner version.
if receipt_passes "$SHA"; then
  echo "verify_pr: existing PASS receipt for $SHA"; exit 0
fi
if [ -f "$(receipt_file "$SHA")" ] && \
   [ "$(jq -r .runner_sha256 "$(receipt_file "$SHA")")" = "$(runner_hash)" ] && \
   [ -f "$CONTROL/transcripts/$SHA.txt" ] && \
   [ "$(jq -r .verdict "$(receipt_file "$SHA")")" = FAIL ] &&    [ "$(jq -r .pytest_exit "$(receipt_file "$SHA")")" != -1 ]; then   # a run that never reached the tests is retried
  echo "verify_pr: existing FAIL receipt for $SHA"; exit 1
fi
chmod u+w "$(receipt_file "$SHA")" "$CONTROL/transcripts/$SHA.txt" 2>/dev/null

SANDBOX_ROOT=/var/lib/candidate-gate
RUN_ID="gate-$(date +%s)-$$"
WORK="$SANDBOX_ROOT/work"
WHEELS="$SANDBOX_ROOT/wheels"
MIRROR="$CONTROL/mirror.git"
TRANSCRIPT="$CONTROL/transcripts/$SHA.txt"
UNITS=()
: > "$TRANSCRIPT"; chmod 600 "$TRANSCRIPT"

exec 8>"$CONTROL/verify.lock"
flock 8

cleanup() {
  local u
  for u in "${UNITS[@]:-}"; do [ -n "$u" ] && sudo -n systemctl stop "$u" 2>/dev/null; done
  sudo -n rm -rf "$WORK" "$WHEELS"
}
trap cleanup EXIT

say() { printf '%s\n' "$*" >> "$TRANSCRIPT"; }
# Candidate text is quoted with a margin, so nobody can mistake it for the runner's own lines.
quote() { head -c 300000 | sed -e 's/^/  | /' >> "$TRANSCRIPT"; }

# ---- the sandbox ----------------------------------------------------------------------------------
BASE_PROPS=(
  -p User=candidate -p Group=candidate -p UMask=0022
  -p NoNewPrivileges=yes -p PrivateTmp=yes -p PrivateDevices=yes -p ProtectSystem=strict -p ProtectHome=yes
  -p ProtectProc=invisible -p ProcSubset=pid -p ProtectKernelTunables=yes -p ProtectKernelModules=yes
  -p ProtectKernelLogs=yes -p ProtectControlGroups=yes -p ProtectClock=yes -p ProtectHostname=yes
  -p RestrictSUIDSGID=yes -p RestrictNamespaces=yes -p LockPersonality=yes -p RestrictRealtime=yes
  -p CapabilityBoundingSet= -p AmbientCapabilities= -p SystemCallArchitectures=native
  -p SystemCallFilter=@system-service -p "SystemCallFilter=~@privileged @mount @debug"
  -p InaccessiblePaths=-/var/log -p InaccessiblePaths=-/var/lib/cloud -p InaccessiblePaths=-/var/lib/caddy
  -p InaccessiblePaths=-/etc/caddy -p InaccessiblePaths=-/root
  -p ReadWritePaths="-$WORK" -p MemoryMax=2G -p CPUQuota=150% -p TasksMax=256 -p LimitCORE=0 -p RuntimeMaxSec=900
  -p Environment=HOME="$WORK/home" -p Environment=PATH="$WORK/venv/bin:/usr/bin:/bin"
  -p Environment=LANG=C.UTF-8 -p Environment=PIP_DISABLE_PIP_VERSION_CHECK=1 -p Environment=PYTHONDONTWRITEBYTECODE=1
)
NO_NET=(-p PrivateNetwork=yes -p "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6")

# Foreground stage: prints the candidate's output, returns its real exit status from systemd.
in_sandbox() {  # <stage> <cwd> <cmd...>
  local stage="$1" cwd="$2"; shift 2
  sudo -n systemd-run --quiet --wait --pipe --collect --service-type=exec --unit="$RUN_ID-$stage" \
    "${BASE_PROPS[@]}" "${NO_NET[@]}" -p WorkingDirectory="$cwd" "$@" </dev/null 2>&1
}

fresh_tree() {
  sudo -n rm -rf "$WORK"
  sudo -n install -d -o candidate -g candidate -m 755 "$WORK" "$WORK/src" "$WORK/home"
  git -C "$MIRROR" archive --format=tar "$SHA" | sudo -n -u candidate tar -x --no-same-owner -C "$WORK/src"
}

fresh_venv() {
  in_sandbox "venv-$1" "$WORK" /usr/bin/python3 -m venv "$WORK/venv" | quote
  [ "${PIPESTATUS[0]}" = 0 ] || return 1
  in_sandbox "deps-$1" "$WORK" "$WORK/venv/bin/pip" install -q --isolated --no-index \
    --find-links "$WHEELS" -r "$WHEELS/requirements.validated.txt" | quote
  [ "${PIPESTATUS[0]}" = 0 ]
}

# requirements.txt is read from the git object, so a symlink is only its target's name, and only plain
# pinned-style requirements pass: no options, paths, URLs or includes. pip then runs in the sandbox with
# wheels only, so no candidate-chosen setup code runs while fetching.
validated_requirements() {
  git -C "$MIRROR" show "$SHA:requirements.txt" 2>/dev/null | python3 -I -c '
import re, sys
ok = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9._,-]+\])?((==|>=|<=|~=|!=|>|<)[A-Za-z0-9.*+!_-]+(,(==|>=|<=|~=|!=|>|<)[A-Za-z0-9.*+!_-]+)*)?$")
out = []
for line in sys.stdin.read().splitlines():
    line = line.split(" #")[0].strip()
    if not line or line.startswith("#"):
        continue
    if not ok.match(line):
        print("REJECTED requirement: " + line[:120], file=sys.stderr)
        sys.exit(1)
    out.append(line)
if not out:
    print("REJECTED: no requirements", file=sys.stderr)
    sys.exit(1)
print("\n".join(out))'
}

fetch_wheels() {
  sudo -n rm -rf "$WHEELS"
  sudo -n install -d -o candidate -g candidate -m 755 "$WHEELS" "$WHEELS/home"
  printf '%s\n' "$1" | sudo -n -u candidate tee "$WHEELS/requirements.validated.txt" >/dev/null
  # Public internet only: loopback, the metadata service and private ranges are unreachable.
  sudo -n systemd-run --quiet --wait --pipe --collect --service-type=exec --unit="$RUN_ID-wheels" \
    "${BASE_PROPS[@]}" -p ReadWritePaths="$WHEELS" -p Environment=HOME="$WHEELS/home" \
    -p IPAddressAllow=127.0.0.53/32 -p IPAddressDeny=127.0.0.0/8 -p IPAddressDeny=::1/128 \
    -p IPAddressDeny=169.254.0.0/16 -p IPAddressDeny=fe80::/10 -p IPAddressDeny=fc00::/7 -p IPAddressDeny=10.0.0.0/8 \
    -p IPAddressDeny=172.16.0.0/12 -p IPAddressDeny=192.168.0.0/16 \
    -p "RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK" -p WorkingDirectory="$WHEELS" \
    /usr/bin/python3 -m pip download -q --isolated --only-binary=:all: --index-url https://pypi.org/simple \
    -d "$WHEELS" -r "$WHEELS/requirements.validated.txt" </dev/null 2>&1 | quote
  local rc="${PIPESTATUS[0]}"
  say "wheel download exit status: $rc"
  sudo -n chown -hR root:root "$WHEELS"
  return "$rc"
}

# ---- the app, in the sandbox, reached only from inside its private network ------------------------
PORT=18081
U="http://127.0.0.1:$PORT"
APP_UNIT=""
APP_N=0
start_app() {  # [feed items json]
  APP_N=$((APP_N + 1))
  APP_UNIT="$RUN_ID-app-$APP_N"
  UNITS+=("$APP_UNIT.service")
  printf '%s' "${1:-}" | sudo -n -u candidate tee "$WORK/feed.json" >/dev/null
  sudo -n systemd-run --quiet --collect --service-type=exec --unit="$APP_UNIT" \
    "${BASE_PROPS[@]}" "${NO_NET[@]}" -p WorkingDirectory="$WORK/src" \
    /bin/sh -c 'if [ -s "$0/feed.json" ]; then FEED_ITEMS_JSON="$(cat "$0/feed.json")"; export FEED_ITEMS_JSON; fi
                exec "$0/venv/bin/uvicorn" app.main:app --host 127.0.0.1 --port "$1" --log-level warning >>"$0/app.log" 2>&1' \
    "$WORK" "$PORT" </dev/null
  local i
  for i in $(seq 1 20); do
    [ "$(http_code GET /health)" = 200 ] && return 0
    sleep 1
  done
  return 1
}
stop_app() { [ -n "$APP_UNIT" ] && sudo -n systemctl stop "$APP_UNIT.service" 2>/dev/null; APP_UNIT=""; }

# Trusted probes run as the candidate user, in the app's own network namespace, with curl's config files
# ignored (-q first). Responses are data: they are only compared, never evaluated.
PROBE_N=0
probe() {  # <curl args...>
  PROBE_N=$((PROBE_N + 1))
  sudo -n systemd-run --quiet --wait --pipe --collect --service-type=exec --unit="$RUN_ID-probe-$PROBE_N" \
    "${BASE_PROPS[@]}" -p PrivateNetwork=yes -p "JoinsNamespaceOf=$APP_UNIT.service" -p "After=$APP_UNIT.service" \
    -p "RestrictAddressFamilies=AF_INET" -p RuntimeMaxSec=30 \
    /usr/bin/curl -q -s --max-time 20 --max-redirs 3 --max-filesize 3000000 --proto =http "$@" </dev/null 2>/dev/null
}
http_code() { [ -n "$APP_UNIT" ] && probe -o /dev/null -w '%{http_code}' -X "$1" "$U$2"; }
fetch() { probe "$U$1"; }
post_form() { probe -L -d "" "$U$1"; }
post_only() { probe -o /dev/null -X POST "$U$1"; }
runs_count() { fetch /runs | jq '.runs | length' 2>/dev/null; }
first_status() { fetch /runs | jq -r '.runs[0].status' 2>/dev/null; }

PAGE=ok
page_check() {  # <label> <pattern> <text>
  if grep -qiE "$2" <<<"$3"; then say "  ok      $1"; else say "  MISSING $1"; PAGE=fail; fi
}
expect() {  # <label> <actual> <wanted>
  if [ "$2" = "$3" ]; then say "  ok      $1"; else say "  MISSING $1 (got $2, wanted $3)"; PAGE=fail; fi
}

black_box_checks() {
  local first action before landed second
  first="$(fetch /)"
  if ! grep -qi '<html' <<<"$first"; then
    say "  MISSING an HTML page at /"
    PAGE=fail
    return
  fi
  say ""; say "Page checks on raw HTML after the first run:"
  page_check "a link for each new item" 'href="https://example\.com/item-[0-9]+"' "$first"
  page_check "says this is the first run" 'first run' "$first"
  page_check "dated briefing" '20[0-9]{2}-[0-9]{2}-[0-9]{2}|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* [0-9]{1,2}' "$first"
  page_check "count of new items" '[0-9]+ new' "$first"
  page_check "history row marked with a check mark" '✓|&check;|&#10003;|&#x2713;' "$first"
  page_check "Run now control" 'run now' "$first"
  # curl runs no JavaScript, so a script that hijacks the form would pass every check below while the
  # button fails in a browser (it did, on PR #18).
  if grep -qiE 'preventDefault|addEventListener\(.submit' <<<"$first"; then
    say "  MISSING a Run now form that works without a script intercepting it"; PAGE=fail
  else
    say "  ok      no script intercepts the Run now form"
  fi

  action="$(grep -oiE 'action="/[^"]*"' <<<"$first" | head -n 1 | cut -d'"' -f2)"
  say ""; say "Run now, through the page's form (action=${action:-none}):"
  [[ "$action" =~ ^/[A-Za-z0-9/_-]*$ ]] || { say "  MISSING a form that posts Run now"; PAGE=fail; return; }
  before="$(runs_count)"
  landed="$(post_form "$action")"
  expect "Run now adds one history row" "$(runs_count)" "$((before + 1))"
  page_check "Run now returns to the page" '<html' "$landed"
  page_check "a run with nothing new says so" '0 new|no new|nothing new' "$(fetch /)"
  before="$(runs_count)"
  second="$(post_form "$action")"
  expect "an immediate second Run now adds no row" "$(runs_count)" "$before"
  page_check "the limited attempt stays on the page" '<html' "$second"
  page_check "the limited attempt tells the user" 'try again|rate.?limit|wait|too (soon|many)|busy' "$second"
  post_only /ingest >/dev/null
  expect "POST /ingest is no way around the limit" "$(runs_count)" "$before"
  sleep 10
  post_form "$action" >/dev/null
  expect "the limit is a minute: a retry after 10 s adds no row" "$(runs_count)" "$before"
  say "  (waiting out the 1-minute limit for the failure and recovery checks)"
  sleep 52
  in_sandbox "failnext" "$WORK/src" "$WORK/venv/bin/python" -m app.ops fail-next | quote
  post_form "$action" >/dev/null
  expect "a failed fetch is stored as a failed run" "$(first_status)" failed
  page_check "the failed run shows a cross" '✗|&cross;|&#10007;|&#x2717;' "$(fetch /)"
  sleep 61
  post_form "$action" >/dev/null
  expect "the next good run succeeds" "$(first_status)" success

  say ""; say "What is new, by item links on the page (A1 to A5):"
  stop_app
  sudo -n -u candidate rm -rf "$WORK/src/data"
  feed_run "A1 first run on 3 items shows 3" 1,2,3 3
  feed_run "A2 same feed shows 0" 1,2,3 0
  feed_run "A3 different order shows 0" 3,1,2 0
  feed_run "A4 one item added shows exactly 1" 1,2,3,4 1
  feed_run "item removed shows 0" 2,3,4 0
  feed_run "A5 removed item coming back shows 0" 1,2,3,4 0
}

feed_run() {  # <label> <item numbers> <wanted links>
  stop_app
  start_app "$(python3 -I -c 'import json, sys; print(json.dumps([{"id": f"item-{i}", "title": f"Item {i}", "link": f"https://example.com/item-{i}"} for i in sys.argv[1].split(",")]))' "$2")" || PAGE=fail
  sleep 1
  expect "$1" "$(fetch / | grep -oE 'href="https://example\.com/item-[0-9]+"' | wc -l)" "$3"
}

# ---- the run --------------------------------------------------------------------------------------
PYTEST_EXIT=-1; CANARY_EXIT=-1; HEALTH=none; REASON=""

finish() {
  local head_after verdict=FAIL
  stop_app
  head_after="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || echo unknown)"
  if [ "$head_after" != "$SHA" ]; then REASON="${REASON:+$REASON; }head moved to $head_after during the run"; fi
  if [ "$PYTEST_EXIT" = 0 ] && [ "$CANARY_EXIT" = 1 ] && [ "$HEALTH" = 200 ] && [ "$PAGE" = ok ] && [ "$head_after" = "$SHA" ]; then
    verdict=PASS
  fi
  say ""; say "runner result: verdict=$verdict pytest_exit=$PYTEST_EXIT canary_exit=$CANARY_EXIT health=$HEALTH page=$PAGE head=$SHA${REASON:+ reason=$REASON}"
  write_receipt "$SHA" "$PR" "$verdict" "$PYTEST_EXIT" "$CANARY_EXIT" "$HEALTH" "$PAGE" "$head_after" "$TRANSCRIPT" "$REASON"
  echo "verify_pr: $verdict for PR #$PR at $SHA"
  [ "$verdict" = PASS ]
  exit $?
}

say "runner head: $SHA  pr: $PR  base: $BASE_BRANCH  (candidate output is quoted with a margin)"

[ -d "$MIRROR" ] || git init -q --bare "$MIRROR"
git -C "$MIRROR" fetch -q --force "https://github.com/$REPO.git" "refs/pull/$PR/head:refs/gate/pr-$PR" 2>&1 | quote
if [ "$(git -C "$MIRROR" rev-parse "refs/gate/pr-$PR" 2>/dev/null)" != "$SHA" ]; then
  REASON="fetched head differs from the approved SHA"; PAGE=fail; say "$REASON"; finish
fi
say "tree: $(git -C "$MIRROR" rev-parse "$SHA^{tree}")"

if ! REQS="$(validated_requirements 2>>"$TRANSCRIPT")"; then
  REASON="requirements.txt refused"; PAGE=fail; say "$REASON"; finish
fi
say ""; say "\$ pip download (sandbox, public internet only, wheels only)"
if ! fetch_wheels "$REQS"; then
  REASON="dependency download failed"; PAGE=fail; say "$REASON"; finish
fi

# Tests on a fresh tree and venv. The canary is a failing test under a random name, collected together with
# every conftest. A runner that does not report it as a failure is not telling the truth about tests.
fresh_tree
if ! fresh_venv tests; then REASON="dependency install failed"; PAGE=fail; finish; fi
NONCE="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf 'def test_%s():\n    assert False\n' "$NONCE" | sudo -n -u candidate tee "$WORK/src/test_$NONCE.py" >/dev/null
in_sandbox canary "$WORK/src" -p Environment=SCHEDULER_ENABLED=false "$WORK/venv/bin/python" -m pytest -q -x -p no:cacheprovider \
  "test_$NONCE.py" . > /dev/null
CANARY_EXIT="$?"
sudo -n -u candidate rm -f "$WORK/src/test_$NONCE.py"
say ""; say "canary run exit status: $CANARY_EXIT (a failing test must give 1)"
[ "$CANARY_EXIT" = 1 ] || REASON="canary: the test runner hid a failing test"

fresh_tree
if ! fresh_venv pytest; then REASON="dependency install failed"; PAGE=fail; finish; fi
say ""; say "\$ pytest -q (sandbox, no network)"
in_sandbox pytest "$WORK/src" -p Environment=SCHEDULER_ENABLED=false "$WORK/venv/bin/python" -m pytest -q -p no:cacheprovider | quote
PYTEST_EXIT="${PIPESTATUS[0]}"
say "pytest exit status from systemd: $PYTEST_EXIT"
if [ "$PYTEST_EXIT" != 0 ]; then
  REASON="${REASON:+$REASON; }tests failed"; PAGE=skipped; finish
fi
[ "$CANARY_EXIT" = 1 ] || { PAGE=skipped; finish; }

# The app on another fresh tree and venv, so the test stage cannot prepare what the checks below see.
fresh_tree
if ! fresh_venv app; then REASON="dependency install failed"; PAGE=fail; finish; fi
say ""; say "\$ uvicorn app.main:app (sandbox, empty database, default scheduler settings)"
if start_app; then HEALTH=200; else HEALTH=000; REASON="${REASON:+$REASON; }app did not answer /health"; PAGE=fail; fi
say "/health: $HEALTH"
if [ "$HEALTH" = 200 ]; then
  [ "$(runs_count)" = 0 ] && post_only /ingest >/dev/null
  black_box_checks
fi
stop_app
say ""; say "app log (last 15 lines):"
sudo -n -u candidate tail -n 15 "$WORK/app.log" 2>/dev/null | cut -c1-300 | quote
[ "$PAGE" = ok ] || REASON="${REASON:+$REASON; }page checks failed"
finish

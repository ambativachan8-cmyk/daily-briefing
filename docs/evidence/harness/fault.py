"""Fault injection against a throwaway copy of the product. No network beyond loopback.
Usage: python fault.py <throwaway copy of the repo> <python with requirements installed>
PASS or FAIL are checks; OBS lines record behaviour for a reader to judge."""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter

ROOT, PY = sys.argv[1], sys.argv[2]
PORT = 18765
U = f"http://127.0.0.1:{PORT}"
DB = os.path.join(ROOT, "data", "briefing.db")


def req(path, m="GET", h=None, timeout=15):
    r = urllib.request.Request(U + path, method=m, headers=h or {}, data=b"" if m == "POST" else None)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as x:
            return x.status, x.read().decode("utf8"), dict(x.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf8"), dict(e.headers)


def start(env=None):
    e = {**os.environ, "SCHEDULER_INTERVAL_SECONDS": "21600", "PYTHONUTF8": "1", **(env or {})}
    p = subprocess.Popen(
        [PY, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", str(PORT), "--log-level", "warning"],
        cwd=ROOT, env=e, stdout=open(os.path.join(ROOT,"server.log"),"a"), stderr=subprocess.STDOUT, text=True,
    )
    for _ in range(50):
        try:
            if req("/health", timeout=1)[0] == 200:
                return p
        except Exception:
            time.sleep(0.2)
    raise SystemExit("no start")


def stop(p, kill=False):
    # Windows venv python.exe is a launcher: kill the whole tree or the real server survives.
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
    else:
        p.kill()
    p.wait(10)
    for _ in range(40):
        try:
            req("/health", timeout=0.3)
            time.sleep(0.2)
        except Exception:
            return
    raise SystemExit("port still answering after stop")


def runs():
    return json.loads(req("/runs")[1])["runs"]


def T(n, ok, detail=""):
    print(("PASS" if ok else "FAIL"), "|", n, "|", str(detail)[:230], flush=True)


def OBS(n, detail=""):
    print("OBS ", "|", n, "|", str(detail)[:230], flush=True)


shutil.rmtree(os.path.join(ROOT, "data"), ignore_errors=True)
p = start()
time.sleep(0.6)
r = runs()
T("fresh start: scheduler tick creates first run", len(r) == 1 and r[0]["is_first_run"] == 1 and r[0]["new_items_count"] > 0, r[:1])
s, b, _ = req("/")
T("page: first run stated in words, items and links visible", s == 200 and "nothing to compare with" in b and 'href="https://example.com/item-1"' in b)
s, b, _ = req("/run-now", "POST")
r2 = runs()
T("Run now adds row with 0 new", s == 200 and len(r2) == 2 and r2[0]["new_items_count"] == 0, (s, len(r2)))
T("page after Run now: 0 new is shown", "0 new" in b and "No new items" in b)
T("page after a 0-new run keeps the earlier briefing", 'id="earlier-briefing"' in b and "example.com/item" in b.split('id="earlier-briefing"')[1])
s, b, _ = req("/run-now", "POST")
T("second click refused, back on the page with a message", s == 200 and "Rate limited" in b, s)
s, b, _ = req("/run-now")
OBS("GET /run-now (reload via address bar after a click)", (s, b[:80]))
s, b, _ = req("/ingest", "POST", {"X-Forwarded-For": "8.8.8.8"})
OBS("direct uvicorn trusts XFF from loopback; matters only if 8000 is exposed (it is loopback on the VM)", s)

n0 = len(runs())
codes = []


def hit(i):
    codes.append(req("/run-now", "POST", {"X-Forwarded-For": f"10.0.0.{i}"}, timeout=30)[0])


ts = [threading.Thread(target=hit, args=(i,)) for i in range(1, 31)]
[t.start() for t in ts]
[t.join() for t in ts]
c = Counter(codes)
r3 = runs()
con = sqlite3.connect(DB)
counts = con.execute("select count(*),count(distinct id) from items").fetchone()
con.close()
T("30 parallel Run now from distinct IPs: no 5xx", not any(x >= 500 for x in codes), dict(c))
T("no duplicate items after flood", counts[0] == counts[1], counts)
T("no run left in 'running' after flood", not [x for x in r3 if x["status"] == "running"], len(r3) - n0)
OBS("failed rows from flood", [x["error"] for x in r3 if x["status"] == "failed"][:2])

subprocess.run([PY, "-m", "app.ops", "fail-next"], cwd=ROOT, capture_output=True)
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.1.0.1"})
r4 = runs()
T("fail switch: run stored failed and shown", r4[0]["status"] == "failed" and "✗" in b and "FAILED" in b, r4[0]["error"])
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.1.0.2"})
r5 = runs()
T("recovery: next run succeeds", r5[0]["status"] == "success", r5[0]["status"])

stop(p, kill=True)
con = sqlite3.connect(DB)
import datetime as _d
con.execute("insert into runs(timestamp,status) values(?,'running')", ((_d.datetime.now(_d.timezone.utc)-_d.timedelta(seconds=1)).isoformat(),))
con.execute("insert or replace into locks values('ingestion','x')")
con.commit()
con.close()
p = start()
time.sleep(0.6)
r6 = runs()
orph = [x for x in r6 if x.get("error") and "Orphaned" in x["error"]]
T("kill -9 mid-run state: orphan marked failed, lock cleared on restart", len(orph) == 1 and not [x for x in r6 if x["status"] == "running"], orph[:1])
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.2.0.1"})
T("run works after crash recovery", s == 200 and runs()[0]["status"] == "success", s)
n_a = len(runs())
stop(p)
p = start()
time.sleep(0.6)
OBS("restart adds a run row (documented wart)", (n_a, len(runs())))
stop(p)

items = json.dumps([{"id": f"item-{i}", "title": f"Item {i}", "link": f"https://example.com/item-{i}", "description": "d"} for i in range(1, 40)])
p = start({"FEED_ITEMS_JSON": items, "SCHEDULER_ENABLED": "false"})
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.3.0.1"})
r = runs()[0]
T("new feed items: only unseen counted and listed", r["new_items_count"] > 0 and b.count('class="new-item"') == r["new_items_count"], (r["new_items_count"], b.count('class="new-item"')))
stop(p)

evil = json.dumps([{"id": "x1", "title": "<script>alert(1)</script>", "link": "javascript:alert(1)", "description": "<img src=x onerror=alert(1)>"}])
p = start({"FEED_ITEMS_JSON": evil, "SCHEDULER_ENABLED": "false"})
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.3.0.2"})
T("feed HTML is escaped", "<script>alert(1)" not in b and "<img src=x" not in b, s)
OBS("javascript: link from a feed is rendered as-is (only reachable if a real feed is added)", 'href="javascript:' in b)
stop(p)

p = start({"FEED_ITEMS_JSON": "{not json", "SCHEDULER_ENABLED": "false"})
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.3.0.3"})
r = runs()[0]
T("malformed source: failed run stored", r["status"] == "failed", r["error"])
stop(p)

p = start({"FEED_ITEMS_JSON": "[1,2,3]", "SCHEDULER_ENABLED": "false"})
s, b, _ = req("/run-now", "POST", {"X-Forwarded-For": "10.3.0.4"})
r = runs()[0]
T("wrong-shape source: failed run stored, no 500", s == 200 and r["status"] == "failed", (s, r["status"], r["error"]))
stop(p)

p = start({"SCHEDULER_ENABLED": "false"})
os.rename(DB, DB + ".moved")
try:
    s, b, _ = req("/", "GET", timeout=4)
    OBS("database removed under a running service: GET /", (s, b[:60]))
except Exception as e:
    OBS("database removed under a running service: GET / raised", repr(e)[:90])
s, b, _ = req("/health", timeout=4)
OBS("database removed under a running service: GET /health", (s, b[:60]))
stop(p)
os.replace(DB + ".moved", DB)

open(DB, "wb").write(b"garbage" * 1000)
p = subprocess.Popen(
    [PY, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", str(PORT), "--log-level", "warning"],
    cwd=ROOT, env={**os.environ, "SCHEDULER_ENABLED": "false", "PYTHONUTF8": "1"},
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(3)
OBS("corrupt database at start: process alive? (Restart=always would loop; recovery is the pre-deploy backup)", p.poll() is None)
if os.name == "nt":
    subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
elif p.poll() is None:
    p.kill()

import asyncio, sqlite3, sys, os
sys.path.insert(0, os.getcwd())
os.environ["SCHEDULER_ENABLED"] = "false"
from fastapi.testclient import TestClient
import app.feed as feed, app.main as main
from app.db import init_db, get_runs
init_db()
real = feed.create_run
def boom(*a, **k): raise sqlite3.OperationalError("database is locked")
feed.create_run = boom
c = TestClient(main.app, raise_server_exceptions=False)
r = c.post("/run-now", headers={"X-Forwarded-For": "1.1.1.1"})
print("Run now during a DB error: HTTP", r.status_code, "| body:", r.text[:40].replace("\n"," "))
print("rows stored for that failure:", len(get_runs()))
feed.create_run = real; main._last_call.clear()
r = c.post("/run-now", headers={"X-Forwarded-For": "1.1.1.2"})
print("next run after the error clears: HTTP", r.status_code, "| latest:", get_runs()[0]["status"])

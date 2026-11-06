"""
End-to-end acceptance tests for scenarios A1-A8 (docs/PRODUCT_BRIEF.md).

One test per scenario, named test_a1_* .. test_a8_*. Every test drives the real
app over HTTP (httpx ASGITransport) against a temporary SQLite database
(data/briefing.db is never touched) with a fully controlled feed supplied via
the FEED_ITEMS_JSON environment variable. Feed failures are forced with
FEED_FAIL=true. Both stored state and the raw HTML of GET / are asserted.
"""

import asyncio
import json
import re
import sqlite3

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

import app.db
import app.main
from app.db import init_db
from app.scheduler import scheduler_loop

ITEM_A = {
    "id": "item-1",
    "title": "First synthetic item",
    "link": "https://example.com/item-1",
    "description": "This is the first synthetic feed item",
}
ITEM_B = {
    "id": "item-2",
    "title": "Second synthetic item",
    "link": "https://example.com/item-2",
    "description": "This is the second synthetic feed item",
}
ITEM_C = {
    "id": "item-3",
    "title": "Third synthetic item",
    "link": "https://example.com/item-3",
    "description": "This is the third synthetic feed item",
}
ITEM_D = {
    "id": "item-4",
    "title": "Fourth synthetic item",
    "link": "https://example.com/item-4",
    "description": "This is the fourth synthetic feed item",
}

THREE_ITEMS = [ITEM_A, ITEM_B, ITEM_C]


@pytest.fixture(autouse=True)
def temp_db(tmp_path, monkeypatch):
    """Point the app at a throwaway database; data/briefing.db is never touched."""
    db_path = tmp_path / "acceptance.db"
    monkeypatch.setattr(app.db, "DB_PATH", db_path)
    monkeypatch.delenv("FEED_ITEMS_JSON", raising=False)
    monkeypatch.delenv("FEED_FAIL", raising=False)
    monkeypatch.delenv("SCHEDULER_ENABLED", raising=False)
    monkeypatch.delenv("SCHEDULER_INTERVAL_SECONDS", raising=False)
    app.main._last_call.clear()
    app.main._run_now_lock = False
    init_db()
    yield db_path
    app.main._last_call.clear()
    app.main._run_now_lock = False


@pytest_asyncio.fixture
async def client():
    transport = ASGITransport(app=app.main.app)
    async with AsyncClient(transport=transport, base_url="http://testserver", follow_redirects=True) as http:
        yield http


def set_feed(monkeypatch, items):
    monkeypatch.setenv("FEED_ITEMS_JSON", json.dumps(items))


def q(db_path, sql, args=()):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(row) for row in conn.execute(sql, args).fetchall()]
    finally:
        conn.close()


def runs_of(db_path):
    return q(db_path, "SELECT * FROM runs ORDER BY id")


async def manual_run(client):
    """One manual Run-now with the rate limiter reset, for isolated scenarios."""
    app.main._last_call.clear()
    return await client.post("/run-now")


@pytest.mark.asyncio
async def test_a1_first_run_on_feed_with_3_items_discovers_3_and_is_first_run(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    resp = await manual_run(client)
    assert resp.status_code == 200

    rows = runs_of(temp_db)
    assert len(rows) == 1
    run = rows[0]
    assert run["status"] == "success"
    assert run["is_first_run"] == 1
    assert run["new_items_count"] == 3

    items = q(temp_db, "SELECT * FROM items")
    assert {i["id"] for i in items} == {"item-1", "item-2", "item-3"}
    seen = q(temp_db, "SELECT * FROM run_items WHERE run_id = ?", (run["id"],))
    assert len(seen) == 3

    html = (await client.get("/")).text
    assert html.count('class="new-item"') == 3
    assert "first run" in html
    assert 'href="https://example.com/item-1"' in html
    assert 'href="https://example.com/item-2"' in html
    assert 'href="https://example.com/item-3"' in html


@pytest.mark.asyncio
async def test_a2_second_identical_run_discovers_0(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    first = await manual_run(client)
    assert first.status_code == 200
    second = await manual_run(client)
    assert second.status_code == 200

    rows = runs_of(temp_db)
    assert len(rows) == 2
    assert rows[0]["new_items_count"] == 3 and rows[0]["is_first_run"] == 1
    assert rows[1]["new_items_count"] == 0 and rows[1]["is_first_run"] == 0
    assert rows[1]["status"] == "success"
    assert len(q(temp_db, "SELECT * FROM items")) == 3

    html = (await client.get("/")).text
    assert html.count('class="new-item"') == 0
    assert "No new items in this run." in html


@pytest.mark.asyncio
async def test_a3_same_items_in_different_order_discover_0(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    await manual_run(client)

    set_feed(monkeypatch, [ITEM_C, ITEM_A, ITEM_B])  # identical items, shuffled
    second = await manual_run(client)
    assert second.status_code == 200

    rows = runs_of(temp_db)
    assert len(rows) == 2
    assert rows[0]["new_items_count"] == 3
    assert rows[1]["new_items_count"] == 0
    assert rows[1]["status"] == "success"
    assert len(q(temp_db, "SELECT * FROM items")) == 3  # no duplicate stored items
    assert len(q(temp_db, "SELECT * FROM run_items WHERE run_id = ?", (rows[1]["id"],))) == 3

    html = (await client.get("/")).text
    assert "No new items in this run." in html


@pytest.mark.asyncio
async def test_a4_adding_one_item_discovers_exactly_1(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    await manual_run(client)

    set_feed(monkeypatch, THREE_ITEMS + [ITEM_D])
    second = await manual_run(client)
    assert second.status_code == 200

    rows = runs_of(temp_db)
    assert len(rows) == 2
    assert rows[1]["new_items_count"] == 1
    assert rows[1]["status"] == "success"
    assert {i["id"] for i in q(temp_db, "SELECT * FROM items")} == {
        "item-1", "item-2", "item-3", "item-4",
    }

    html = (await client.get("/")).text
    assert html.count('class="new-item"') == 1  # exactly one new-item link
    assert 'href="https://example.com/item-4"' in html
    assert "Fourth synthetic item" in html


@pytest.mark.asyncio
async def test_a5_reintroduced_old_item_discovers_0(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    await manual_run(client)

    set_feed(monkeypatch, [ITEM_A, ITEM_B])  # item-3 disappears
    removed = await manual_run(client)
    assert removed.status_code == 200

    set_feed(monkeypatch, THREE_ITEMS)  # item-3 re-appears
    back = await manual_run(client)
    assert back.status_code == 200

    rows = runs_of(temp_db)
    assert len(rows) == 3
    assert [r["new_items_count"] for r in rows] == [3, 0, 0]
    assert rows[2]["status"] == "success"
    assert len(q(temp_db, "SELECT * FROM items")) == 3  # item-3 was never re-added

    html = (await client.get("/")).text
    assert "No new items in this run." in html


@pytest.mark.asyncio
async def test_a6_failed_fetch_stored_as_failed_then_next_run_recovers(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    await manual_run(client)

    monkeypatch.setenv("FEED_FAIL", "true")
    failed = await manual_run(client)
    assert failed.status_code == 200  # the page is still served after a failed run

    rows = runs_of(temp_db)
    assert len(rows) == 2
    assert rows[1]["status"] == "failed"
    assert rows[1]["error"]  # the failure reason is stored
    assert rows[1]["new_items_count"] == 0

    html = (await client.get("/")).text
    assert "✗" in html  # failed run marked in history
    assert rows[1]["error"] in html  # ...with its error

    monkeypatch.delenv("FEED_FAIL", raising=False)
    recovered = await manual_run(client)
    assert recovered.status_code == 200

    rows = runs_of(temp_db)
    assert len(rows) == 3
    assert rows[2]["status"] == "success"
    assert rows[2]["new_items_count"] == 0  # same items as run 1: nothing new
    assert rows[2]["error"] is None

    html = (await client.get("/")).text
    newest_row = html.split("<tbody>")[1].split("</tr>")[0]
    assert "✓" in newest_row and "✗" not in newest_row  # the newest row is the recovered run
    assert "This run failed" not in html  # the failure no longer heads the page
    assert "No new items in this run." in html


@pytest.mark.asyncio
async def test_a7_public_page_and_history_load_without_login(client, monkeypatch, temp_db):
    set_feed(monkeypatch, THREE_ITEMS)
    await manual_run(client)

    resp = await client.get("/")  # no credentials, no cookies, no headers
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    html = resp.text

    assert "Latest Briefing" in html  # latest briefing visible
    assert 'href="https://example.com/item-1"' in html
    assert "Run History" in html  # history visible
    assert "first run" in html
    assert "✓" in html
    assert re.search(r"<td>\s*3\s*</td>", html)  # new-items count column
    assert "login" not in html.lower()  # no login gate on the public page


@pytest.mark.asyncio
async def test_a8_run_now_adds_row_rate_limited_no_overlap_and_scheduler_tick(client, monkeypatch, temp_db):
    # (a) A manual Run-now adds a history row.
    set_feed(monkeypatch, THREE_ITEMS)
    resp = await manual_run(client)
    assert resp.status_code == 200
    assert "Run History" in resp.text
    assert len(runs_of(temp_db)) == 1

    # (b) Run-now is rate-limited.
    limited = await client.post("/run-now")
    assert limited.status_code == 200
    assert "Rate limited" in limited.text
    assert len(runs_of(temp_db)) == 1  # the rate-limited call started no run

    # (c) Two runs never execute at the same time.
    started = asyncio.Event()
    release = asyncio.Event()
    ingest_calls = []

    async def slow_ingest():
        ingest_calls.append(1)
        started.set()
        await release.wait()
        return {"status": "success", "new_items_count": 0, "run_id": None}

    monkeypatch.setattr(app.main, "ingest_feed", slow_ingest)
    app.main._last_call.clear()  # the in-flight run must pass the rate limiter
    in_flight = asyncio.create_task(client.post("/run-now"))
    await asyncio.wait_for(started.wait(), timeout=5)  # first run holds the lock
    app.main._last_call.clear()  # isolate the overlap guard from the rate limiter
    try:
        # Bounded, so a missing guard fails this test instead of hanging the suite.
        second = await asyncio.wait_for(client.post("/run-now"), timeout=5)
    finally:
        release.set()
    assert second.status_code == 200
    assert "already in progress" in second.text
    first_resp = await asyncio.wait_for(in_flight, timeout=5)
    assert first_resp.status_code == 200
    assert ingest_calls == [1]  # the second request did not start a second ingest
    assert len(runs_of(temp_db)) == 1  # ...and stored no run row

    # (d) One scheduler tick, called directly, ingests and adds a history row.
    set_feed(monkeypatch, THREE_ITEMS + [ITEM_D])
    monkeypatch.setenv("SCHEDULER_ENABLED", "true")
    monkeypatch.setenv("SCHEDULER_INTERVAL_SECONDS", "3600")
    tick = asyncio.create_task(scheduler_loop())
    try:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + 5
        while len(runs_of(temp_db)) < 2 and loop.time() < deadline:
            await asyncio.sleep(0.05)
        rows = runs_of(temp_db)
        assert len(rows) == 2
        assert rows[1]["status"] == "success"
        assert rows[1]["new_items_count"] == 1  # item-4 was new for the tick
        assert rows[1]["is_first_run"] == 0
    finally:
        tick.cancel()
        try:
            await tick
        except asyncio.CancelledError:
            pass
        assert len(runs_of(temp_db)) == 2  # a large interval means no further ticks

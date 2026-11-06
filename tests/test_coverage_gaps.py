"""
Requirements the suite did not cover: each broken version listed in issue #23 must fail here.
"""
import asyncio
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

import app.db
import app.main
import app.scheduler
from app.db import get_runs, init_db
from app.feed import ingest_feed

REAL_DATA_DIR = Path(app.db.__file__).resolve().parent.parent / "data"


@pytest.fixture(autouse=True)
def fresh_state():
    app.main._last_call.clear()
    app.main._run_now_lock = False
    init_db()
    yield
    app.main._last_call.clear()
    app.main._run_now_lock = False


@pytest_asyncio.fixture
async def client():
    transport = ASGITransport(app=app.main.app)
    async with AsyncClient(transport=transport, base_url="http://test", follow_redirects=True) as http:
        yield http


def test_tests_never_use_the_real_database():
    assert REAL_DATA_DIR not in app.db.get_db_path().resolve().parents


@pytest.mark.parametrize("path", ["/run-now", "/ingest"])
@pytest.mark.asyncio
async def test_rate_limit_is_a_full_minute(client, monkeypatch, path):
    clock = {"now": 1000.0}
    monkeypatch.setattr(app.main, "time", lambda: clock["now"])

    await client.post(path)
    assert len(get_runs()) == 1

    clock["now"] += 59
    await client.post(path)
    assert len(get_runs()) == 1  # one second short of a minute: refused

    clock["now"] += 1
    await client.post(path)
    assert len(get_runs()) == 2  # a full minute: allowed


@pytest.mark.asyncio
async def test_ingest_refuses_with_429_and_shares_the_limit_with_run_now(client):
    await client.post("/run-now")
    response = await client.post("/ingest")
    assert response.status_code == 429
    assert len(get_runs()) == 1


@pytest.mark.asyncio
async def test_scheduler_keeps_ticking_at_its_configured_interval(monkeypatch):
    monkeypatch.setenv("SCHEDULER_INTERVAL_SECONDS", "7")
    monkeypatch.setenv("SCHEDULER_ENABLED", "true")
    ingest = AsyncMock(return_value={"status": "success", "new_items_count": 0})
    monkeypatch.setattr(app.scheduler, "ingest_feed", ingest)
    sleeps = []

    async def fake_sleep(seconds):
        sleeps.append(seconds)
        if len(sleeps) == 3:
            raise asyncio.CancelledError

    monkeypatch.setattr(app.scheduler.asyncio, "sleep", fake_sleep)
    with pytest.raises(asyncio.CancelledError):
        await app.scheduler.scheduler_loop()

    assert sleeps == [7, 7, 7]
    assert ingest.await_count == 3


@pytest.mark.asyncio
async def test_page_shows_the_run_date(client):
    await ingest_feed(current_time=datetime(2026, 10, 14, 9, 5, tzinfo=timezone.utc))
    briefing = (await client.get("/")).text.split('class="history"')[0]
    assert re.search(r"Oct 14|2026-10-14", briefing)


@pytest.mark.asyncio
async def test_feed_text_is_escaped_on_the_page(client, monkeypatch):
    monkeypatch.setenv(
        "FEED_ITEMS_JSON",
        json.dumps([{
            "id": "x1",
            "title": "<script>alert(1)</script>",
            "link": "https://example.com/x1",
            "description": "<img src=x onerror=alert(1)>",
        }]),
    )
    await client.post("/run-now")
    html = (await client.get("/")).text
    assert "<script>alert(1)" not in html
    assert "<img src=x" not in html
    assert "&lt;script&gt;alert(1)" in html

"""
Regression tests covering items 1-6 requested by the owner.
"""
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
import tempfile
import pytest

from app.db import init_db, get_db_path, get_runs, get_run, get_items_by_run, set_config
from app.feed import ingest_feed, fetch_feed, get_feed_items, FEED_START_DATE
from app.ops import main as ops_main


@pytest.fixture
def temp_db(monkeypatch):
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = Path(tmpdir) / "test.db"
        monkeypatch.setattr("app.db.DB_PATH", db_path)
        monkeypatch.setattr("app.db.get_db_path", lambda: db_path)
        init_db()
        yield db_path


@pytest.mark.asyncio
async def test_regression_1_metadata_persistence(temp_db):
    """1. Ingest, reopen storage, then read the run's items and assert title and link."""
    res = await ingest_feed(current_time=FEED_START_DATE)
    assert res["status"] == "success"
    run_id = res["run_id"]

    items = get_items_by_run(run_id)
    assert len(items) > 0
    for item in items:
        assert item["title"]
        assert item["link"]


@pytest.mark.asyncio
async def test_regression_2_second_run_seen_vs_new(temp_db):
    """2. Second identical run: 0 new, still 3 seen, with is_new flag working correctly."""
    res1 = await ingest_feed(current_time=FEED_START_DATE)
    assert res1["status"] == "success"
    assert res1["new_items_count"] == 3

    res2 = await ingest_feed(current_time=FEED_START_DATE)
    assert res2["status"] == "success"
    assert res2["new_items_count"] == 0

    run2_items = get_items_by_run(res2["run_id"])
    assert len(run2_items) == 3
    for item in run2_items:
        assert not bool(item["is_new"])


def test_regression_3_dynamic_feed_growth():
    """3. Same instant gives identical feed; a later instant gives a strict superset with unchanged IDs."""
    t1 = FEED_START_DATE
    feed1 = get_feed_items(current_time=t1)

    feed2 = get_feed_items(current_time=t1)
    assert feed1 == feed2

    t3 = FEED_START_DATE + timedelta(days=1)
    feed3 = get_feed_items(current_time=t3)
    assert len(feed3) > len(feed1)
    for orig in feed1:
        match = next((item for item in feed3 if item["id"] == orig["id"]), None)
        assert match is not None
        assert match["link"] == orig["link"]


@pytest.mark.asyncio
async def test_regression_4_operator_fail_command(temp_db, monkeypatch):
    """4. Operator fail command makes next run fail (✗) and following one succeed (✓)."""
    monkeypatch.setattr(sys, "argv", ["ops.py", "fail-next"])
    ops_main()

    res_fail = await ingest_feed(current_time=FEED_START_DATE)
    assert res_fail["status"] == "failed"

    res_success = await ingest_feed(current_time=FEED_START_DATE)
    assert res_success["status"] == "success"
    assert res_success["new_items_count"] == 3


@pytest.mark.asyncio
async def test_regression_5_lock_concurrency(temp_db):
    """5. While a run holds the lock, second call returns busy at once in under 1s with no new row."""
    import threading
    import asyncio
    import time
    from unittest.mock import patch

    event_start = threading.Event()
    event_release = threading.Event()

    async def blocking_fetch(*args, **kwargs):
        event_start.set()
        event_release.wait(timeout=5)
        return [{"id": "b-1", "title": "Blocked", "link": "https://example.com/b1", "description": "desc"}], None

    with patch("app.feed.fetch_feed", side_effect=blocking_fetch):
        import concurrent.futures

        def run_first():
            return asyncio.run(ingest_feed())

        with concurrent.futures.ThreadPoolExecutor() as executor:
            future = executor.submit(run_first)
            assert event_start.wait(timeout=3)

            t0 = time.time()
            res2 = await ingest_feed()
            t1 = time.time()

            assert (t1 - t0) < 1.0
            assert res2["status"] == "failed"
            assert res2["run_id"] is None
            assert res2["new_items_count"] == 0
            assert "Another ingestion is already running" in res2["error"]

            event_release.set()
            res1 = future.result(timeout=5)
            assert res1["status"] == "success"


@pytest.mark.asyncio
async def test_regression_6_rollback_on_failure(temp_db, monkeypatch):
    """6. Force a failure after items are inserted; run is ✗, and next good run reports those items as new."""
    from unittest.mock import patch
    import app.db as db_module
    original_insert_items = db_module.insert_items

    def mock_fail_after_insert(items, conn=None):
        res = original_insert_items(items, conn=conn)
        raise RuntimeError("Forced failure after items insertion")

    with patch("app.feed.insert_items", side_effect=mock_fail_after_insert):
        res_fail = await ingest_feed(current_time=FEED_START_DATE)
        assert res_fail["status"] == "failed"

    res_good = await ingest_feed(current_time=FEED_START_DATE)
    assert res_good["status"] == "success"
    assert res_good["new_items_count"] == 3


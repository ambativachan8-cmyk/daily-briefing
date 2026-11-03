"""
Tests for the feed and ingestion logic.
"""
import os
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
import pytest_asyncio

from app.db import create_run, get_all_item_ids, init_db, insert_items
from app.feed import (
    fetch_feed,
    generate_item_id,
    get_feed_items,
    ingest_feed,
    should_feed_fail,
)


@pytest.fixture(autouse=True)
def reset_env():
    """Reset environment variables before each test."""
    old_env = dict(os.environ)
    # Remove test-related env vars
    for key in ["FEED_ITEMS_JSON", "FEED_FAIL"]:
        os.environ.pop(key, None)
    yield
    os.environ.clear()
    os.environ.update(old_env)


def test_generate_item_id_uses_feed_id():
    """Test that generate_item_id uses the feed's own id when present."""
    item = {"id": "custom-id-123", "link": "https://example.com/item"}
    assert generate_item_id(item) == "custom-id-123"


def test_generate_item_id_hashes_link_when_no_id():
    """Test that generate_item_id hashes the link when no id is present."""
    item = {"link": "https://example.com/item"}
    item_id = generate_item_id(item)
    # Should be a deterministic hash of the link
    assert len(item_id) == 16
    assert item_id == generate_item_id(item)  # Deterministic


def test_generate_item_id_different_links_different_ids():
    """Test that different links produce different IDs."""
    item1 = {"link": "https://example.com/item-1"}
    item2 = {"link": "https://example.com/item-2"}
    assert generate_item_id(item1) != generate_item_id(item2)


def test_get_feed_items_default(reset_env):
    """Test get_feed_items returns default items when no env var."""
    items = get_feed_items()
    assert len(items) == 3
    assert items[0]["id"] == "item-1"
    assert items[1]["id"] == "item-2"
    assert items[2]["id"] == "item-3"


def test_get_feed_items_from_env(reset_env):
    """Test get_feed_items reads from FEED_ITEMS_JSON env var."""
    custom_items = [
        {"id": "custom-1", "title": "Custom 1", "link": "https://example.com/c1"},
        {"id": "custom-2", "title": "Custom 2", "link": "https://example.com/c2"},
    ]
    os.environ["FEED_ITEMS_JSON"] = str(custom_items).replace("'", '"')
    items = get_feed_items()
    assert len(items) == 2
    assert items[0]["id"] == "custom-1"
    assert items[1]["id"] == "custom-2"


def test_should_feed_fail_false_by_default(reset_env):
    """Test should_feed_fail returns False by default."""
    assert should_feed_fail() is False


def test_should_feed_fail_true_when_set(reset_env):
    """Test should_feed_fail returns True when FEED_FAIL=true."""
    os.environ["FEED_FAIL"] = "true"
    assert should_feed_fail() is True


def test_should_feed_fail_case_insensitive(reset_env):
    """Test should_feed_fail is case insensitive."""
    os.environ["FEED_FAIL"] = "TRUE"
    assert should_feed_fail() is True
    os.environ["FEED_FAIL"] = "False"
    assert should_feed_fail() is False


@pytest.mark.asyncio
async def test_fetch_feed_success(temp_db, reset_env):
    """Test fetch_feed returns items on success."""
    items, error = await fetch_feed()
    assert error is None
    assert len(items) == 3
    assert items[0]["id"] == "item-1"


@pytest.mark.asyncio
async def test_fetch_feed_fails_when_configured(temp_db, reset_env):
    """Test fetch_feed returns error when FEED_FAIL=true."""
    os.environ["FEED_FAIL"] = "true"
    items, error = await fetch_feed()
    assert error is not None
    assert "Feed configured to fail" in error
    assert items == []


# Ingestion tests (A1-A5 scenarios)


@pytest_asyncio.fixture
async def temp_db(monkeypatch):
    """Create a temporary database for testing."""
    import tempfile
    from pathlib import Path

    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = Path(tmpdir) / "test.db"
        monkeypatch.setattr("app.db.DB_PATH", db_path)
        monkeypatch.setattr("app.db.get_db_path", lambda: db_path)
        init_db()
        yield db_path


@pytest.mark.asyncio
async def test_ingest_first_run_three_items(temp_db, reset_env):
    """
    A1: First run on a feed with 3 items -> 3 new, marked as first run.
    """
    result = await ingest_feed()

    assert result["status"] == "success"
    assert result["new_items_count"] == 3
    assert result["is_first_run"] is True
    assert len(result["new_items"]) == 3
    assert {item["id"] for item in result["new_items"]} == {
        "item-1",
        "item-2",
        "item-3",
    }


@pytest.mark.asyncio
async def test_ingest_second_run_identical_feed(temp_db, reset_env):
    """
    A2: Second run, identical feed -> 0 new.
    """
    # First run
    result1 = await ingest_feed()
    assert result1["new_items_count"] == 3

    # Second run with identical feed
    result2 = await ingest_feed()
    assert result2["status"] == "success"
    assert result2["new_items_count"] == 0
    assert result2["is_first_run"] is False
    assert len(result2["new_items"]) == 0


@pytest.mark.asyncio
async def test_ingest_same_items_different_order(temp_db, reset_env):
    """
    A3: Same items, different order -> 0 new.
    """
    # First run with default order
    result1 = await ingest_feed()
    assert result1["new_items_count"] == 3

    # Second run with reversed order (simulate via env var)
    os.environ["FEED_ITEMS_JSON"] = str(
        [
            {"id": "item-3", "title": "Third", "link": "https://example.com/item-3"},
            {"id": "item-2", "title": "Second", "link": "https://example.com/item-2"},
            {"id": "item-1", "title": "First", "link": "https://example.com/item-1"},
        ]
    ).replace("'", '"')

    result2 = await ingest_feed()
    assert result2["status"] == "success"
    assert result2["new_items_count"] == 0
    assert len(result2["new_items"]) == 0


@pytest.mark.asyncio
async def test_ingest_one_item_added(temp_db, reset_env):
    """
    A4: One item added -> exactly 1 new.
    """
    # First run with 3 items
    result1 = await ingest_feed()
    assert result1["new_items_count"] == 3

    # Second run with 4 items (one added)
    os.environ["FEED_ITEMS_JSON"] = str(
        [
            {"id": "item-1", "title": "First", "link": "https://example.com/item-1"},
            {"id": "item-2", "title": "Second", "link": "https://example.com/item-2"},
            {"id": "item-3", "title": "Third", "link": "https://example.com/item-3"},
            {"id": "item-4", "title": "Fourth", "link": "https://example.com/item-4"},
        ]
    ).replace("'", '"')

    result2 = await ingest_feed()
    assert result2["status"] == "success"
    assert result2["new_items_count"] == 1
    assert len(result2["new_items"]) == 1
    assert result2["new_items"][0]["id"] == "item-4"


@pytest.mark.asyncio
async def test_ingest_previously_seen_item_reappears(temp_db, reset_env):
    """
    A5: A previously seen item re-appears after being removed -> 0 new.
    """
    # First run with 3 items
    result1 = await ingest_feed()
    assert result1["new_items_count"] == 3

    # Second run with only 2 items (item-2 removed)
    os.environ["FEED_ITEMS_JSON"] = str(
        [
            {"id": "item-1", "title": "First", "link": "https://example.com/item-1"},
            {"id": "item-3", "title": "Third", "link": "https://example.com/item-3"},
        ]
    ).replace("'", '"')

    result2 = await ingest_feed()
    assert result2["status"] == "success"
    assert result2["new_items_count"] == 0

    # Third run with item-2 re-appearing
    os.environ["FEED_ITEMS_JSON"] = str(
        [
            {"id": "item-1", "title": "First", "link": "https://example.com/item-1"},
            {"id": "item-2", "title": "Second", "link": "https://example.com/item-2"},
            {"id": "item-3", "title": "Third", "link": "https://example.com/item-3"},
        ]
    ).replace("'", '"')

    result3 = await ingest_feed()
    assert result3["status"] == "success"
    assert result3["new_items_count"] == 0
    assert len(result3["new_items"]) == 0


@pytest.mark.asyncio
async def test_ingest_feed_failure_stored(temp_db, reset_env):
    """
    A6: Feed fetch fails -> run stored as failed with error.
    """
    os.environ["FEED_FAIL"] = "true"

    result = await ingest_feed()

    assert result["status"] == "failed"
    assert result["error"] is not None
    assert "Feed configured to fail" in result["error"]
    assert result["new_items_count"] == 0


@pytest.mark.asyncio
async def test_ingest_after_failure_succeeds(temp_db, reset_env):
    """
    After a failed run, a good run succeeds and reports correctly.
    """
    # First run fails
    os.environ["FEED_FAIL"] = "true"
    result1 = await ingest_feed()
    assert result1["status"] == "failed"

    # Second run succeeds
    os.environ["FEED_FAIL"] = "false"
    result2 = await ingest_feed()
    assert result2["status"] == "success"
    assert result2["new_items_count"] == 3
    assert result2["is_first_run"] is True  # First successful run (no items were stored before)
"""
Tests for the database module.
"""
import tempfile
from pathlib import Path

import pytest

from app.db import (
    create_run,
    get_all_item_ids,
    get_db_path,
    get_items_by_run,
    get_run,
    get_runs,
    init_db,
    insert_items,
    item_exists,
    update_run_status,
)


@pytest.fixture
def temp_db(monkeypatch):
    """Create a temporary database for testing."""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = Path(tmpdir) / "test.db"
        monkeypatch.setattr("app.db.DB_PATH", db_path)
        monkeypatch.setattr("app.db.get_db_path", lambda: db_path)
        init_db()
        yield db_path


def test_init_db_creates_tables(temp_db):
    """Test that init_db creates the required tables."""
    # Tables should exist after init_db
    import sqlite3

    conn = sqlite3.connect(temp_db)
    cursor = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )
    tables = {row[0] for row in cursor.fetchall()}
    conn.close()

    assert "runs" in tables
    assert "items" in tables


def test_create_and_get_run(temp_db):
    """Test creating and retrieving a run."""
    timestamp = "2026-01-01T12:00:00Z"
    run_id = create_run(timestamp, "success")

    assert run_id == 1

    run = get_run(run_id)
    assert run is not None
    assert run["id"] == 1
    assert run["timestamp"] == timestamp
    assert run["status"] == "success"
    assert run["error"] is None


def test_create_run_with_error(temp_db):
    """Test creating a run with an error."""
    run_id = create_run("2026-01-01T12:00:00Z", "failed", "Connection timeout")

    run = get_run(run_id)
    assert run["status"] == "failed"
    assert run["error"] == "Connection timeout"


def test_update_run_status(temp_db):
    """Test updating a run's status."""
    run_id = create_run("2026-01-01T12:00:00Z", "running")
    update_run_status(run_id, "success")

    run = get_run(run_id)
    assert run["status"] == "success"


def test_get_runs_ordered_desc(temp_db):
    """Test that runs are returned in descending timestamp order."""
    create_run("2026-01-01T10:00:00Z", "success")
    create_run("2026-01-01T12:00:00Z", "success")
    create_run("2026-01-01T11:00:00Z", "success")

    runs = get_runs()
    assert len(runs) == 3
    assert runs[0]["timestamp"] == "2026-01-01T12:00:00Z"
    assert runs[1]["timestamp"] == "2026-01-01T11:00:00Z"
    assert runs[2]["timestamp"] == "2026-01-01T10:00:00Z"


def test_insert_items(temp_db):
    """Test inserting items."""
    run_id = create_run("2026-01-01T12:00:00Z", "success")

    items = [
        ("item-1", "feed-1", run_id),
        ("item-2", "feed-1", run_id),
        ("item-3", "feed-2", run_id),
    ]
    count = insert_items(items)

    assert count == 3
    assert item_exists("item-1")
    assert item_exists("item-2")
    assert item_exists("item-3")


def test_insert_items_ignore_duplicates(temp_db):
    """Test that duplicate items are ignored."""
    run_id = create_run("2026-01-01T12:00:00Z", "success")

    items = [("item-1", "feed-1", run_id)]
    insert_items(items)
    count = insert_items(items)  # Insert same items again

    assert count == 0  # No new items inserted
    assert item_exists("item-1")


def test_get_items_by_run(temp_db):
    """Test retrieving items by run ID."""
    run_id = create_run("2026-01-01T12:00:00Z", "success")

    items = [
        ("item-1", "feed-1", run_id),
        ("item-2", "feed-1", run_id),
    ]
    insert_items(items)

    run_items = get_items_by_run(run_id)
    assert len(run_items) == 2
    assert {row["id"] for row in run_items} == {"item-1", "item-2"}


def test_get_all_item_ids(temp_db):
    """Test getting all known item IDs."""
    run_id = create_run("2026-01-01T12:00:00Z", "success")

    items = [
        ("item-1", "feed-1", run_id),
        ("item-2", "feed-1", run_id),
    ]
    insert_items(items)

    all_ids = get_all_item_ids()
    assert all_ids == {"item-1", "item-2"}


def test_item_exists(temp_db):
    """Test checking if an item exists."""
    run_id = create_run("2026-01-01T12:00:00Z", "success")
    insert_items([("item-1", "feed-1", run_id)])

    assert item_exists("item-1")
    assert not item_exists("item-2")


def test_get_run_not_found(temp_db):
    """Test getting a non-existent run."""
    run = get_run(999)
    assert run is None
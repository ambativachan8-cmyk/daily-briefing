"""
Synthetic feed generation and ingestion logic.
"""
import hashlib
import json
import os
from datetime import datetime, timezone
from typing import Any

from app.db import (
    acquire_lock,
    cleanup_stale_runs,
    create_run,
    get_all_item_ids,
    get_config,
    insert_items,
    insert_run_items,
    set_config,
    update_run_status,
)

# Fixed constant start date for the dynamic feed
FEED_START_DATE = datetime(2026, 11, 4, 0, 0, tzinfo=timezone.utc)

DEFAULT_FEED_ITEMS = [
    {
        "id": "item-1",
        "title": "First synthetic item",
        "link": "https://example.com/item-1",
        "description": "This is the first synthetic feed item",
    },
    {
        "id": "item-2",
        "title": "Second synthetic item",
        "link": "https://example.com/item-2",
        "description": "This is the second synthetic feed item",
    },
    {
        "id": "item-3",
        "title": "Third synthetic item",
        "link": "https://example.com/item-3",
        "description": "This is the third synthetic feed item",
    },
]


def generate_item_id(item: dict[str, Any]) -> str:
    """
    Generate a stable ID for an item.
    Uses the feed's own id if present, otherwise hashes the link.
    """
    if "id" in item and item["id"]:
        return str(item["id"])
    link = item.get("link", "")
    return hashlib.sha256(link.encode()).hexdigest()[:16]


def get_feed_items(current_time: datetime | None = None) -> list[dict[str, Any]]:
    """
    Get the synthetic feed items.
    Can be overridden via FEED_ITEMS_JSON environment variable for testing.
    Otherwise dynamic based on time from FEED_START_DATE (gains an item every 6 hours).
    """
    feed_json = os.environ.get("FEED_ITEMS_JSON")
    if feed_json:
        try:
            return json.loads(feed_json)
        except json.JSONDecodeError:
            raise ValueError("Invalid FEED_ITEMS_JSON environment variable")

    now = current_time or datetime.now(timezone.utc)
    hours_elapsed = max(0.0, (now - FEED_START_DATE).total_seconds() / 3600)
    num_items = 3 + int(hours_elapsed // 6)

    items = []
    for i in range(num_items):
        item_id = f"item-{i+1}"
        items.append({
            "id": item_id,
            "title": f"Item {i+1} title",
            "link": f"https://example.com/item-{i+1}",
            "description": f"Description for item {i+1}",
        })
    return items


def _check_feed_fail_config(conn=None) -> bool:
    """Check if the feed should fail (for testing) without consuming the config."""
    if conn is not None:
        try:
            row = conn.execute("SELECT value FROM config WHERE key = 'fail_next_run'").fetchone()
            db_fail = row["value"] if row else None
        except Exception:
            db_fail = None
    else:
        db_fail = get_config("fail_next_run")
    if db_fail and db_fail.lower() == "true":
        return True
    return os.environ.get("FEED_FAIL", "false").lower() == "true"


def _consume_feed_fail_config(conn=None) -> bool:
    """Check and consume the feed fail config."""
    if conn is not None:
        try:
            row = conn.execute("SELECT value FROM config WHERE key = 'fail_next_run'").fetchone()
            db_fail = row["value"] if row else None
            if db_fail and db_fail.lower() == "true":
                conn.execute("INSERT OR REPLACE INTO config (key, value) VALUES ('fail_next_run', 'false')")
                return True
        except Exception:
            pass
    else:
        db_fail = get_config("fail_next_run")
        if db_fail and db_fail.lower() == "true":
            set_config("fail_next_run", "false")
            return True
    return os.environ.get("FEED_FAIL", "false").lower() == "true"


async def fetch_feed(consume_config: bool = False, conn=None, current_time: datetime | None = None) -> tuple[list[dict[str, Any]], str | None]:
    """
    Fetch the synthetic feed.
    Returns (items, error_message).
    """
    should_fail = _consume_feed_fail_config(conn=conn) if consume_config else _check_feed_fail_config(conn=conn)
    if should_fail:
        return [], "Feed configured to fail (fail_next_run=true)"

    try:
        items = get_feed_items(current_time=current_time)
        return items, None
    except ValueError as e:
        return [], str(e)


async def ingest_feed(current_time: datetime | None = None) -> dict[str, Any]:
    """
    Ingest the feed: fetch, compare with stored items, store new items and run atomically.
    Database errors are caught and stored as failed runs when possible, or logged when not.
    No exception escapes this function.
    """
    import logging
    timestamp = (current_time or datetime.now(timezone.utc)).isoformat()

    with acquire_lock("ingestion") as acquired:
        if not acquired:
            return {
                "run_id": None,
                "timestamp": timestamp,
                "status": "failed",
                "error": "Another ingestion is already running",
                "new_items_count": 0,
                "new_items": [],
                "is_first_run": False,
            }

        from app.db import get_conn
        conn = None
        run_id = None
        try:
            conn_cm = get_conn()
            conn = conn_cm.__enter__()
            run_id = create_run(timestamp, "running", conn=conn)
            conn.commit()

            feed_items, error = await fetch_feed(consume_config=True, conn=conn, current_time=current_time)

            if error:
                update_run_status(run_id, "failed", error, new_items_count=0, is_first_run=False, conn=conn)
                conn.commit()
                conn_cm.__exit__(None, None, None)
                return {
                    "run_id": run_id,
                    "timestamp": timestamp,
                    "status": "failed",
                    "error": error,
                    "new_items_count": 0,
                    "new_items": [],
                    "is_first_run": False,
                }

            known_ids = get_all_item_ids()
            is_first_run = len(known_ids) == 0

            new_items = []
            all_items_in_run = []
            for item in feed_items:
                item_id = generate_item_id(item)
                all_items_in_run.append((
                    run_id,
                    item_id,
                    item.get("title", ""),
                    item.get("link", ""),
                    item.get("description", "")
                ))
                if item_id not in known_ids:
                    new_items.append(
                        (
                            item_id,
                            item.get("id", item_id),
                            item.get("title", ""),
                            item.get("link", ""),
                            item.get("description", ""),
                            run_id,
                        )
                    )
                    known_ids.add(item_id)

            if new_items:
                insert_items(new_items, conn=conn)
            insert_run_items(all_items_in_run, conn=conn)

            update_run_status(run_id, "success", None, new_items_count=len(new_items), is_first_run=is_first_run, conn=conn)
            conn.commit()
            conn_cm.__exit__(None, None, None)

            return {
                "run_id": run_id,
                "timestamp": timestamp,
                "status": "success",
                "error": None,
                "new_items_count": len(new_items),
                "new_items": [{"id": i[0], "title": i[2], "link": i[3], "description": i[4]} for i in new_items],
                "is_first_run": is_first_run,
            }

        except Exception as e:
            # Database error during run - try to store as failed run if DB is writable
            if run_id is not None and conn is not None:
                try:
                    conn.rollback()
                except Exception:
                    pass
                try:
                    update_run_status(run_id, "failed", str(e), new_items_count=0, is_first_run=False, conn=conn)
                    conn.commit()
                    if conn_cm:
                        conn_cm.__exit__(None, None, None)
                    return {
                        "run_id": run_id,
                        "timestamp": timestamp,
                        "status": "failed",
                        "error": str(e),
                        "new_items_count": 0,
                        "new_items": [],
                        "is_first_run": False,
                    }
                except Exception:
                    # Cannot write failed run to DB - log it
                    logging.error(f"Failed to store failed run {run_id}: {e}")
            else:
                # Could not even create run - log it
                logging.error(f"Database error before run creation: {e}")
            return {
                "run_id": run_id,
                "timestamp": timestamp,
                "status": "failed",
                "error": str(e),
                "new_items_count": 0,
                "new_items": [],
                "is_first_run": False,
            }
        finally:
            if conn is not None and 'conn_cm' in locals():
                try:
                    conn_cm.__exit__(None, None, None)
                except Exception:
                    pass


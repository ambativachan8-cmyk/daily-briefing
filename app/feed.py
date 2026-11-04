"""
Synthetic feed generation and ingestion logic.
"""
import hashlib
import json
import os
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any

from app.db import (
    acquire_lock,
    cleanup_stale_runs,
    create_run,
    get_all_item_ids,
    get_config,
    insert_items,
    set_config,
    update_run_status,
)

# Default feed items for the synthetic feed - these will be the base items
# The feed can "gain items over time" by adding new items with new stable IDs
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


def get_feed_items() -> list[dict[str, Any]]:
    """
    Get the synthetic feed items.
    Can be overridden via FEED_ITEMS_JSON environment variable for testing.
    Falls back to default items on JSON decode error.
    """
    feed_json = os.environ.get("FEED_ITEMS_JSON")
    if feed_json:
        try:
            return json.loads(feed_json)
        except json.JSONDecodeError:
            # Invalid JSON - will be handled as error in fetch_feed
            raise ValueError("Invalid FEED_ITEMS_JSON environment variable")
    return DEFAULT_FEED_ITEMS


def _check_feed_fail_config() -> bool:
    """
    Check if the feed should fail (for testing) without consuming the config.
    Checks database config first, then environment variable.
    """
    # Check database config (non-public way to control feed failure)
    db_fail = get_config("fail_next_run")
    if db_fail and db_fail.lower() == "true":
        return True
    # Fallback to environment variable
    return os.environ.get("FEED_FAIL", "false").lower() == "true"


def _consume_feed_fail_config() -> bool:
    """
    Check and consume the feed fail config.
    Returns True if the feed should fail this one time.
    """
    # Check database config (non-public way to control feed failure)
    db_fail = get_config("fail_next_run")
    if db_fail and db_fail.lower() == "true":
        # Consume the config so it only fails once
        set_config("fail_next_run", "false")
        return True
    # Fallback to environment variable (not consumed, for testing)
    return os.environ.get("FEED_FAIL", "false").lower() == "true"


async def fetch_feed(consume_config: bool = False) -> tuple[list[dict[str, Any]], str | None]:
    """
    Fetch the synthetic feed.
    Returns (items, error_message).
    If error_message is not None, the fetch failed.
    
    Args:
        consume_config: If True, consume the fail_next_run config (for ingestion).
                       If False, just check without consuming (for /feed endpoint).
    """
    should_fail = _consume_feed_fail_config() if consume_config else _check_feed_fail_config()
    if should_fail:
        return [], "Feed configured to fail (fail_next_run=true)"

    # In a real implementation, this would fetch from an external URL.
    # For the synthetic feed, we return the configured items directly.
    try:
        items = get_feed_items()
        return items, None
    except ValueError as e:
        return [], str(e)


async def ingest_feed() -> dict[str, Any]:
    """
    Ingest the feed: fetch, compare with stored items, store new items and run.
    Returns a summary of the run.
    Uses a lock to prevent overlapping runs across threads and processes.
    """
    # Clean up any stale runs from previous crashes
    cleanup_stale_runs()

    timestamp = datetime.now(timezone.utc).isoformat()

    # Acquire lock to prevent overlapping runs
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

        # Create a run record (initially "running")
        run_id = create_run(timestamp, "running")

        try:
            # Fetch the feed (consume config if set)
            feed_items, error = await fetch_feed(consume_config=True)

            if error:
                # Feed fetch failed
                update_run_status(run_id, "failed", error, new_items_count=0, is_first_run=False)
                return {
                    "run_id": run_id,
                    "timestamp": timestamp,
                    "status": "failed",
                    "error": error,
                    "new_items_count": 0,
                    "new_items": [],
                    "is_first_run": False,
                }

            # Get all known item IDs
            known_ids = get_all_item_ids()
            is_first_run = len(known_ids) == 0

            # Determine new items (deterministic dedup by stable ID)
            new_items = []
            for item in feed_items:
                item_id = generate_item_id(item)
                if item_id not in known_ids:
                    new_items.append(
                        {
                            "id": item_id,
                            "feed_id": item.get("id", item_id),
                            "title": item.get("title", ""),
                            "link": item.get("link", ""),
                            "description": item.get("description", ""),
                        }
                    )
                    known_ids.add(item_id)  # Track for this run

            # Store new items AND update run status atomically (in same transaction)
            if new_items:
                items_to_insert = [
                    (item["id"], item["feed_id"], run_id) for item in new_items
                ]
                insert_items(items_to_insert)

            # Update run status to success with details
            update_run_status(run_id, "success", None, new_items_count=len(new_items), is_first_run=is_first_run)

            return {
                "run_id": run_id,
                "timestamp": timestamp,
                "status": "success",
                "error": None,
                "new_items_count": len(new_items),
                "new_items": new_items,
                "is_first_run": is_first_run,
            }

        except Exception as e:
            # Unexpected error during ingestion
            update_run_status(run_id, "failed", str(e), new_items_count=0, is_first_run=False)
            return {
                "run_id": run_id,
                "timestamp": timestamp,
                "status": "failed",
                "error": str(e),
                "new_items_count": 0,
                "new_items": [],
                "is_first_run": False,
            }
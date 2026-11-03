"""
Synthetic feed generation and ingestion logic.
"""
import hashlib
import json
import os
from datetime import datetime, timezone
from typing import Any

import httpx

from app.db import (
    create_run,
    get_all_item_ids,
    insert_items,
    update_run_status,
)

# Default feed items for the synthetic feed
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
    """
    feed_json = os.environ.get("FEED_ITEMS_JSON")
    if feed_json:
        try:
            return json.loads(feed_json)
        except json.JSONDecodeError:
            pass
    return DEFAULT_FEED_ITEMS


def should_feed_fail() -> bool:
    """Check if the feed should fail (for testing)."""
    return os.environ.get("FEED_FAIL", "false").lower() == "true"


async def fetch_feed() -> tuple[list[dict[str, Any]], str | None]:
    """
    Fetch the synthetic feed.
    Returns (items, error_message).
    If error_message is not None, the fetch failed.
    """
    if should_feed_fail():
        return [], "Feed configured to fail (FEED_FAIL=true)"

    # In a real implementation, this would fetch from an external URL.
    # For the synthetic feed, we return the configured items directly.
    items = get_feed_items()
    return items, None


async def ingest_feed() -> dict[str, Any]:
    """
    Ingest the feed: fetch, compare with stored items, store new items and run.
    Returns a summary of the run.
    """
    timestamp = datetime.now(timezone.utc).isoformat()

    # Create a run record (initially "running")
    run_id = create_run(timestamp, "running")

    try:
        # Fetch the feed
        feed_items, error = await fetch_feed()

        if error:
            # Feed fetch failed
            update_run_status(run_id, "failed", error)
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

        # Store new items
        if new_items:
            items_to_insert = [
                (item["id"], item["feed_id"], run_id) for item in new_items
            ]
            insert_items(items_to_insert)

        # Update run status to success
        update_run_status(run_id, "success")

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
        update_run_status(run_id, "failed", str(e))
        return {
            "run_id": run_id,
            "timestamp": timestamp,
            "status": "failed",
            "error": str(e),
            "new_items_count": 0,
            "new_items": [],
            "is_first_run": False,
        }
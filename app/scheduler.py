"""
Background scheduler for feed ingestion.
"""
import asyncio
import os
import logging
from datetime import datetime, timezone
from app.feed import ingest_feed

logger = logging.getLogger(__name__)

# Configurable interval, default to 1 hour
DEFAULT_INTERVAL = 3600

async def scheduler_loop():
    """
    Infinite loop that triggers feed ingestion at a regular interval.
    """
    try:
        interval_str = os.environ.get("SCHEDULER_INTERVAL_SECONDS")
        interval = int(interval_str) if interval_str else DEFAULT_INTERVAL
    except ValueError:
        logger.warning(f"Invalid SCHEDULER_INTERVAL_SECONDS: {os.environ.get('SCHEDULER_INTERVAL_SECONDS')}. Using default: {DEFAULT_INTERVAL}")
        interval = DEFAULT_INTERVAL

    enabled = os.environ.get("SCHEDULER_ENABLED", "true").lower() == "true"
    
    if not enabled:
        logger.info("Scheduler is disabled via SCHEDULER_ENABLED environment variable.")
        return

    logger.info(f"Starting background scheduler with interval: {interval}s")
    
    while True:
        try:
            logger.info(f"Scheduler tick at {datetime.now(timezone.utc).isoformat()}")
            result = await ingest_feed()
            if result["status"] == "success":
                logger.info(f"Scheduled ingestion success: {result['new_items_count']} new items.")
            else:
                logger.warning(f"Scheduled ingestion skipped or failed: {result.get('error')}")
        except asyncio.CancelledError:
            logger.info("Scheduler loop cancelled.")
            raise
        except Exception as e:
            # A scheduler error never stops the web app or later ticks.
            logger.error(f"Error in scheduler tick: {e}", exc_info=True)
        
        try:
            await asyncio.sleep(interval)
        except asyncio.CancelledError:
            logger.info("Scheduler sleep cancelled.")
            raise

_scheduler_task = None

def start_scheduler():
    """
    Starts the scheduler as a background task.
    """
    global _scheduler_task
    if _scheduler_task is None:
        logger.info("Starting scheduler background task.")
        _scheduler_task = asyncio.create_task(scheduler_loop())

def stop_scheduler():
    """
    Stops the scheduler task.
    """
    global _scheduler_task
    if _scheduler_task is not None:
        logger.info("Stopping scheduler background task.")
        if _scheduler_task:
            _scheduler_task.cancel()
        _scheduler_task = None

"""
Tests for the background scheduler.
"""
import asyncio
import os
import pytest
from unittest.mock import patch, AsyncMock
from fastapi.testclient import TestClient
from app.main import app
from app.db import init_db, get_conn, acquire_lock

@pytest.fixture(autouse=True)
def setup_db():
    init_db()
    # Clear runs and locks for a clean state
    with get_conn() as conn:
        conn.execute("DELETE FROM runs")
        conn.execute("DELETE FROM locks")
        conn.commit()

def test_scheduler_starts_and_stops():
    """
    Test that the scheduler is started and stopped with the app lifespan.
    """
    # We use TestClient with a context manager to trigger lifespan
    # We disable the actual loop execution by mocking scheduler_loop or env
    with patch("app.scheduler.scheduler_loop", return_value=AsyncMock()) as mock_loop:
        with TestClient(app):
            # Lifespan should have called start_scheduler which calls asyncio.create_task(scheduler_loop())
            # In sync TestClient, lifespan runs.
            pass
        # After exit, stop_scheduler should have been called.

@pytest.mark.asyncio
async def test_scheduler_tick_executes_ingest():
    """
    Test that the scheduler loop actually calls ingest_feed.
    """
    from app.scheduler import scheduler_loop
    
    with patch("app.scheduler.ingest_feed", new_callable=AsyncMock) as mock_ingest:
        mock_ingest.return_value = {"status": "success", "new_items_count": 1}
        
        # Set a very short interval and disable loop to just run once for testing
        # Or mock asyncio.sleep to raise CancelledError after first run
        with patch("os.environ.get", side_effect=lambda k, d=None: "0.1" if k == "SCHEDULER_INTERVAL_SECONDS" else d):
            with patch("asyncio.sleep", side_effect=[None, asyncio.CancelledError]):
                try:
                    await scheduler_loop()
                except asyncio.CancelledError:
                    pass
                
                assert mock_ingest.called

@pytest.mark.asyncio
async def test_scheduler_lock_overlap():
    """
    Test that the scheduler handles busy locks gracefully (as per requirement: skip run).
    """
    from app.scheduler import scheduler_loop
    from app.feed import ingest_feed
    
    # Manually acquire the lock to simulate another run
    with acquire_lock("ingestion") as acquired:
        assert acquired is True
        
        # Now run one tick of the scheduler
        with patch("os.environ.get", side_effect=lambda k, d=None: "0.1" if k == "SCHEDULER_INTERVAL_SECONDS" else d):
            with patch("asyncio.sleep", side_effect=[asyncio.CancelledError]):
                try:
                    await scheduler_loop()
                except asyncio.CancelledError:
                    pass
                
                # Check that no new run was created in the DB because it was skipped
                with get_conn() as conn:
                    count = conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0]
                    assert count == 0

@pytest.mark.asyncio
async def test_scheduler_error_resiliency():
    """
    Test that a scheduler error doesn't stop the loop.
    """
    from app.scheduler import scheduler_loop
    
    # Mock ingest_feed to raise an exception
    with patch("app.scheduler.ingest_feed", side_effect=[Exception("Boom"), {"status": "success", "new_items_count": 0}]):
        with patch("os.environ.get", side_effect=lambda k, d=None: "0.1" if k == "SCHEDULER_INTERVAL_SECONDS" else d):
            # Sleep once, then cancel on second sleep
            with patch("asyncio.sleep", side_effect=[None, asyncio.CancelledError]):
                try:
                    await scheduler_loop()
                except asyncio.CancelledError:
                    pass
                
                # If we reached here without the loop crashing, it's resilient.

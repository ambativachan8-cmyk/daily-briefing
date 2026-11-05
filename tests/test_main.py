"""
Tests for the main FastAPI application.
"""
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from app.main import app, _ingest_last_call, _run_now_last_call, _run_now_lock
from app.db import get_db_path


@pytest.fixture(autouse=True)
def reset_state():
    """Reset global state and clear database before each test."""
    # Clear rate limiters
    _ingest_last_call.clear()
    _run_now_last_call.clear()
    # Reset lock
    import app.main
    app.main._run_now_lock = False
    
    # Clear database
    db_path = get_db_path()
    if db_path.exists():
        import sqlite3
        conn = sqlite3.connect(db_path)
        conn.execute("DELETE FROM runs")
        conn.execute("DELETE FROM items")
        conn.execute("DELETE FROM run_items")
        conn.execute("DELETE FROM locks")
        conn.commit()
        conn.close()
    
    yield
    
    # Cleanup after test
    _ingest_last_call.clear()
    _run_now_last_call.clear()
    app.main._run_now_lock = False


@pytest_asyncio.fixture
async def async_client():
    """Create an async test client."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


@pytest.mark.asyncio
async def test_health_check(async_client):
    """Test the health check endpoint."""
    response = await async_client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "timestamp" in data


@pytest.mark.asyncio
async def test_root_endpoint(async_client):
    """Test the root endpoint returns HTML with briefing page structure."""
    response = await async_client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("content-type", "")
    html = response.text
    assert "Daily Briefing" in html
    assert "Latest Briefing" in html
    assert "Run History" in html
    assert "Run Now" in html


@pytest.mark.asyncio
async def test_root_endpoint_shows_no_runs_when_empty(async_client):
    """Test root endpoint shows empty state when no runs exist."""
    response = await async_client.get("/")
    assert response.status_code == 200
    html = response.text
    assert "No runs recorded yet" in html


@pytest.mark.asyncio
async def test_run_now_endpoint(async_client):
    """Test the run-now endpoint triggers ingestion."""
    response = await async_client.post("/run-now")
    assert response.status_code == 200
    data = response.json()
    assert "run_id" in data
    assert "status" in data
    assert data["status"] in ("success", "failed")
    assert "new_items_count" in data
    assert "timestamp" in data


@pytest.mark.asyncio
async def test_run_now_rate_limit(async_client):
    """Test run-now endpoint rate limits."""
    # First request should succeed
    await async_client.post("/run-now")
    
    # Second request immediately should be rate limited
    response = await async_client.post("/run-now")
    assert response.status_code == 429
    data = response.json()
    assert "retry_after_seconds" in data


@pytest.mark.asyncio
async def test_ingest_endpoint(async_client):
    """Test the ingest endpoint."""
    response = await async_client.post("/ingest")
    assert response.status_code == 200
    data = response.json()
    assert "run_id" in data
    assert "status" in data
    assert data["status"] in ("success", "failed")
    assert "new_items_count" in data
    assert "timestamp" in data


@pytest.mark.asyncio
async def test_runs_endpoint(async_client):
    """Test the runs history endpoint."""
    # Trigger a run first
    await async_client.post("/ingest")
    
    response = await async_client.get("/runs")
    assert response.status_code == 200
    data = response.json()
    assert "runs" in data
    assert isinstance(data["runs"], list)
    assert len(data["runs"]) > 0
    run = data["runs"][0]
    assert "id" in run
    assert "timestamp" in run
    assert "status" in run
    assert "new_items_count" in run


@pytest.mark.asyncio
async def test_run_detail_endpoint(async_client):
    """Test the run detail endpoint."""
    # Trigger a run first
    ingest_resp = await async_client.post("/ingest")
    ingest_data = ingest_resp.json()
    assert "run_id" in ingest_data, f"Ingest response missing run_id: {ingest_data}"
    run_id = ingest_data["run_id"]
    
    response = await async_client.get(f"/runs/{run_id}")
    assert response.status_code == 200
    data = response.json()
    assert "run" in data
    assert "items" in data
    assert data["run"]["id"] == run_id
    assert isinstance(data["items"], list)
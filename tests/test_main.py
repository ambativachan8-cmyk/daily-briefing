
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from app.main import app


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
    """Test the root endpoint."""
    response = await async_client.get("/")
    assert response.status_code == 200
    data = response.json()
    assert data["message"] == "Daily Briefing API"
    assert data["version"] == "0.1.0"

@pytest.mark.asyncio
async def test_run_now(async_client):
    """Test the run-now endpoint."""
    response = await async_client.post("/run-now")
    assert response.status_code == 200
    # Change "items" to "new_items"
    assert "new_items" in response.json()


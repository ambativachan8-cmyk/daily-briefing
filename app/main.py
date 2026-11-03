"""
Main FastAPI application.
"""
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from app.db import init_db, get_runs, get_run, get_items_by_run
from app.feed import fetch_feed, ingest_feed, should_feed_fail, get_feed_items


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    # Startup
    init_db()
    yield
    # Shutdown (if needed)


app = FastAPI(
    title="Daily Briefing",
    description="Scheduled feed ingestion and briefing generation",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health_check():
    """Minimal health check endpoint."""
    return JSONResponse(
        content={
            "status": "ok",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    )


@app.get("/")
async def root():
    """Root endpoint."""
    return {"message": "Daily Briefing API", "version": "0.1.0"}


@app.get("/feed")
async def feed_endpoint():
    """
    Synthetic feed endpoint.
    Returns the feed items or an error if configured to fail.
    """
    if should_feed_fail():
        return JSONResponse(
            status_code=500,
            content={
                "error": "Feed configured to fail (FEED_FAIL=true)",
                "items": [],
            },
        )

    items = get_feed_items()
    return {"items": items}


@app.post("/ingest")
async def ingest_endpoint():
    """
    Trigger a feed ingestion run.
    Fetches the feed, determines new items, stores them, and records the run.
    """
    result = await ingest_feed()
    return JSONResponse(content=result)


@app.get("/runs")
async def runs_endpoint(limit: int = 100):
    """
    Get run history.
    """
    runs = get_runs(limit)
    return {"runs": [dict(run) for run in runs]}


@app.get("/runs/{run_id}")
async def run_detail_endpoint(run_id: int):
    """
    Get details for a specific run including its items.
    """
    run = get_run(run_id)
    if not run:
        return JSONResponse(status_code=404, content={"error": "Run not found"})

    items = get_items_by_run(run_id)
    return {
        "run": dict(run),
        "items": [dict(item) for item in items],
    }
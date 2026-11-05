from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse
"""
Main FastAPI application.
"""
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from time import time

from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.responses import JSONResponse

from app.db import cleanup_stale_runs, get_items_by_run, get_runs, get_run, init_db
from app.feed import _check_feed_fail_config, fetch_feed, get_feed_items, ingest_feed
from app.scheduler import start_scheduler, stop_scheduler

# Simple in-memory rate limiter for /ingest endpoint
_ingest_last_call: dict[str, float] = {}
INGEST_RATE_LIMIT_SECONDS = 5  # Minimum 5 seconds between runs


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    init_db()
    cleanup_stale_runs()
    start_scheduler()
    yield
    stop_scheduler()


app = FastAPI(
    title="Daily Briefing",
    description="Scheduled feed ingestion and briefing generation",
    version="0.1.0",
    lifespan=lifespan,
)


def check_rate_limit(client_ip: str) -> tuple[bool, float | None]:
    """Check if client is rate limited. Returns (allowed, retry_after_seconds)."""
    now = time()
    last = _ingest_last_call.get(client_ip)
    if last is not None:
        elapsed = now - last
        if elapsed < INGEST_RATE_LIMIT_SECONDS:
            return False, INGEST_RATE_LIMIT_SECONDS - elapsed
    _ingest_last_call[client_ip] = now
    return True, None


@app.get("/health")
async def health_check():
    """Minimal health check endpoint."""
    return JSONResponse(
        content={
            "status": "ok",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    )


@app.get("/", response_class=HTMLResponse)
async def root(request: Request):
    """Root endpoint."""
    runs = get_runs(limit=10)
    latest_run = runs[0] if runs else None
    items = get_items_by_run(latest_run.id) if latest_run else []
    return templates.TemplateResponse("index.html", {"request": request, "latest_run": latest_run, "items": items, "runs": runs})

templates = Jinja2Templates(directory="templates")


@app.get("/feed")
async def feed_endpoint():
    """
    Synthetic feed endpoint.
    Returns the feed items or an error if configured to fail.
    """
    if _check_feed_fail_config():
        return JSONResponse(
            status_code=500,
            content={
                "error": "Feed configured to fail (fail_next_run=true)",
                "items": [],
            },
        )

    items = get_feed_items()
    return {"items": items}


@app.post("/ingest")
async def ingest_endpoint(request: Request):
    """
    Trigger a feed ingestion run.
    Rate limited to prevent abuse.
    """
    client_ip = request.client.host if request.client else "unknown"
    allowed, retry_after = check_rate_limit(client_ip)
    if not allowed:
        # For a simple form app, maybe we just redirect back with a query param for error
        return RedirectResponse(url="/?error=rate_limited", status_code=303)

    await ingest_feed()
    return RedirectResponse(url="/", status_code=303)


@app.get("/runs")
async def runs_endpoint(limit: int = 100):
    """
    Get run history.
    Limit is bounded between 1 and 1000.
    """
    if limit < 1:
        limit = 100
    elif limit > 1000:
        limit = 1000

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

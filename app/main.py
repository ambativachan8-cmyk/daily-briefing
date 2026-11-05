"""
Main FastAPI application.
"""
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from time import time

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from app.db import cleanup_stale_runs, get_items_by_run, get_runs, get_run, init_db
from app.feed import _check_feed_fail_config, fetch_feed, get_feed_items, ingest_feed
from app.scheduler import start_scheduler, stop_scheduler

# Simple in-memory rate limiter shared by /ingest and /run-now endpoints
_last_call: dict[str, float] = {}
RATE_LIMIT_SECONDS = 60  # Minimum 60 seconds between runs

# Lock to prevent overlapping runs
_run_now_lock: bool = False


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

templates = Jinja2Templates(directory="templates")


def check_rate_limit(client_ip: str) -> tuple[bool, float | None]:
    """Check if client is rate limited. Returns (allowed, retry_after_seconds)."""
    now = time()
    last = _last_call.get(client_ip)
    if last is not None:
        elapsed = now - last
        if elapsed < RATE_LIMIT_SECONDS:
            return False, RATE_LIMIT_SECONDS - elapsed
    _last_call[client_ip] = now
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
    """Root endpoint - serves the public briefing page."""
    runs = get_runs(limit=100)
    latest_run = dict(runs[0]) if runs else None
    latest_items = []
    if latest_run:
        items = get_items_by_run(latest_run["id"])
        latest_items = [dict(item) for item in items]
    
    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "runs": [dict(run) for run in runs],
            "latest_run": latest_run,
            "latest_items": latest_items,
        },
    )


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
        return JSONResponse(
            status_code=429,
            content={
                "error": "Rate limited. Try again later.",
                "retry_after_seconds": round(retry_after, 1),
            },
        )

    # Check for overlapping runs
    global _run_now_lock
    if _run_now_lock:
        return JSONResponse(
            status_code=409,
            content={"error": "Another run is already in progress. Please wait."},
        )

    _run_now_lock = True
    try:
        result = await ingest_feed()
        return JSONResponse(content=result)
    finally:
        _run_now_lock = False


@app.post("/run-now")
async def run_now_endpoint(request: Request):
    """
    Manual run trigger from the web UI.
    Rate limited and prevents overlapping runs.
    Returns HTML (redirect to /) for plain form submissions.
    """
    client_ip = request.client.host if request.client else "unknown"
    
    # Check rate limit
    allowed, retry_after = check_rate_limit(client_ip)
    if not allowed:
        # Return HTML page with rate limit message
        runs = get_runs(limit=100)
        latest_run = dict(runs[0]) if runs else None
        latest_items = []
        if latest_run:
            items = get_items_by_run(latest_run["id"])
            latest_items = [dict(item) for item in items]
        
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "runs": [dict(run) for run in runs],
                "latest_run": latest_run,
                "latest_items": latest_items,
                "rate_limit_msg": f"Rate limited. Try again in {round(retry_after, 1)}s.",
            },
            status_code=429,
        )
    
    # Check for overlapping runs
    global _run_now_lock
    if _run_now_lock:
        runs = get_runs(limit=100)
        latest_run = dict(runs[0]) if runs else None
        latest_items = []
        if latest_run:
            items = get_items_by_run(latest_run["id"])
            latest_items = [dict(item) for item in items]
        
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "runs": [dict(run) for run in runs],
                "latest_run": latest_run,
                "latest_items": latest_items,
                "rate_limit_msg": "Another run is already in progress. Please wait.",
            },
            status_code=409,
        )
    
    _run_now_lock = True
    try:
        await ingest_feed()
        # Redirect to root to show updated page
        from fastapi.responses import RedirectResponse
        return RedirectResponse(url="/", status_code=303)
    finally:
        _run_now_lock = False


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
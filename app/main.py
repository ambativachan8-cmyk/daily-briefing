"""
Main FastAPI application.
"""
import logging
import sqlite3
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from time import time

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from app.db import (
    cleanup_stale_runs,
    get_items_by_run,
    get_latest_run_with_new_items,
    get_run,
    get_runs,
    init_db,
)
from app.feed import _check_feed_fail_config, fetch_feed, get_feed_items, ingest_feed
from app.scheduler import start_scheduler, stop_scheduler

# Simple in-memory rate limiter shared by /ingest and /run-now endpoints
_last_call: dict[str, float] = {}
RATE_LIMIT_SECONDS = 60  # Minimum 60 seconds between runs

# Lock to prevent overlapping runs
_run_now_lock: bool = False

logger = logging.getLogger(__name__)

# The only messages /?notice= can show, so the URL cannot put text on the page.
NOTICES = {
    "rate-limited": "Rate limited. Run Now works once a minute. Try again shortly.",
    "busy": "Another run is already in progress. Please wait.",
    "unsaved": "That run failed and could not be saved. The error has been logged.",
}


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



def format_when(value: str) -> str:
    """Turn a stored ISO time into 'Nov 6, 2026, 08:32 UTC'."""
    try:
        when = datetime.fromisoformat(value).astimezone(timezone.utc)
    except (TypeError, ValueError):
        return value
    return f"{when:%b} {when.day}, {when.year}, {when:%H:%M} UTC"


templates = Jinja2Templates(directory=str(Path(__file__).resolve().parent.parent / "templates"))
templates.env.filters["when"] = format_when


@app.exception_handler(sqlite3.Error)
@app.exception_handler(OSError)
async def database_unavailable(request: Request, exc: Exception):
    """A database that cannot be read or reached gets a plain message, not a raw 500."""
    logger.error("Database error on %s: %s", request.url.path, exc)
    return PlainTextResponse("The briefing is unavailable right now. Please try again shortly.", status_code=503)


def _back_to_page(notice: str | None = None) -> RedirectResponse:
    return RedirectResponse(f"/?notice={notice}" if notice else "/", status_code=303)


def _page_context(notice: str | None = None) -> dict:
    """Everything the public page shows."""
    runs = [dict(run) for run in get_runs(limit=100)]
    latest_run = runs[0] if runs else None
    latest_items = [dict(item) for item in get_items_by_run(latest_run["id"])] if latest_run else []

    # A quiet or failed run has nothing to list, so the last briefing that did stays visible.
    earlier_run = None
    earlier_items = []
    if latest_run and not latest_run["new_items_count"]:
        found = get_latest_run_with_new_items()
        if found:
            earlier_run = dict(found)
            earlier_items = [dict(item) for item in get_items_by_run(earlier_run["id"])]

    return {
        "runs": runs,
        "latest_run": latest_run,
        "latest_items": latest_items,
        "earlier_run": earlier_run,
        "earlier_items": earlier_items,
        "notice": NOTICES.get(notice),
    }


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
async def root(request: Request, notice: str | None = None):
    """Root endpoint - serves the public briefing page."""
    return templates.TemplateResponse(request, "index.html", _page_context(notice))


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
    Rate limited and prevents overlapping runs. Always answers with a redirect to the page,
    so the browser ends on / and reloading it cannot start another run.
    """
    client_ip = request.client.host if request.client else "unknown"

    allowed, _ = check_rate_limit(client_ip)
    if not allowed:
        return _back_to_page("rate-limited")

    global _run_now_lock
    if _run_now_lock:
        return _back_to_page("busy")

    _run_now_lock = True
    try:
        result = await ingest_feed()
    finally:
        _run_now_lock = False

    if result.get("skipped"):
        return _back_to_page("busy")
    if result["status"] == "failed" and result["run_id"] is None:
        return _back_to_page("unsaved")
    return _back_to_page()


@app.get("/run-now")
async def run_now_address_bar():
    """Opening the URL directly starts nothing; it just goes to the page."""
    return _back_to_page()


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
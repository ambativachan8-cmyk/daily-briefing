"""
Issues #21, #22 and #24: what a visitor sees after each kind of run, and how a database error ends.
"""
import json
import re
import sqlite3

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

import app.db
import app.feed
import app.main
from app.db import acquire_lock, get_runs, init_db

ITEM = {"id": "a", "title": "Item A", "link": "https://example.com/a", "description": "first"}
NEXT = {"id": "b", "title": "Item B", "link": "https://example.com/b", "description": "second"}


@pytest.fixture(autouse=True)
def fresh_state():
    app.main._last_call.clear()
    app.main._run_now_lock = False
    init_db()
    yield
    app.main._last_call.clear()
    app.main._run_now_lock = False


@pytest_asyncio.fixture
async def browser():
    """Follows redirects, as a browser does."""
    transport = ASGITransport(app=app.main.app)
    async with AsyncClient(transport=transport, base_url="http://test", follow_redirects=True) as http:
        yield http


@pytest_asyncio.fixture
async def raw():
    """Shows the redirect itself."""
    transport = ASGITransport(app=app.main.app)
    async with AsyncClient(transport=transport, base_url="http://test") as http:
        yield http


def set_feed(monkeypatch, items):
    monkeypatch.setenv("FEED_ITEMS_JSON", json.dumps(items))


async def run(client):
    app.main._last_call.clear()
    return await client.post("/run-now")


def execute(sql):
    conn = sqlite3.connect(app.db.get_db_path())
    conn.execute(sql)
    conn.commit()
    conn.close()


def latest_part(html):
    return html.split('id="earlier-briefing"')[0].split('class="history"')[0]


def earlier_part(html):
    assert 'id="earlier-briefing"' in html
    return html.split('id="earlier-briefing"')[1].split('class="history"')[0]


# ---- #21: the briefing stays useful ----------------------------------------------------------------


@pytest.mark.asyncio
async def test_first_run_says_in_words_that_everything_is_new(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    page = (await run(browser)).text
    assert "there was nothing to compare with, so everything is new" in latest_part(page)
    assert 'first-run-badge">first run' in latest_part(page)
    assert 'id="earlier-briefing"' not in page


@pytest.mark.asyncio
async def test_later_run_does_not_claim_to_be_the_first(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    await run(browser)
    set_feed(monkeypatch, [ITEM, NEXT])
    page = (await run(browser)).text
    assert "nothing to compare with" not in page
    assert "1 new since the last run" in page


@pytest.mark.asyncio
async def test_quiet_run_says_so_and_keeps_the_last_briefing_labelled_as_earlier(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    await run(browser)
    page = (await run(browser)).text

    assert "No new items in this run." in latest_part(page)
    assert "example.com/a" not in latest_part(page)  # nothing is presented as new

    earlier = earlier_part(page)
    assert "Earlier Briefing" in earlier
    assert 'href="https://example.com/a"' in earlier
    assert "1 new in that run" in earlier
    assert re.search(r"[A-Z][a-z]{2} \d{1,2}, \d{4}, \d{2}:\d{2} UTC", earlier)


@pytest.mark.asyncio
async def test_earlier_briefing_is_the_most_recent_with_items(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    await run(browser)
    set_feed(monkeypatch, [ITEM, NEXT])
    await run(browser)
    earlier = earlier_part((await run(browser)).text)
    assert "example.com/b" in earlier
    assert "example.com/a" not in earlier  # item A belongs to an older briefing


@pytest.mark.asyncio
async def test_failed_run_also_keeps_the_last_briefing_visible(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    await run(browser)
    monkeypatch.setenv("FEED_FAIL", "true")
    page = (await run(browser)).text
    assert "This run failed" in latest_part(page)
    assert "example.com/a" in earlier_part(page)


@pytest.mark.asyncio
async def test_failed_first_run_has_no_earlier_briefing(browser, monkeypatch):
    monkeypatch.setenv("FEED_FAIL", "true")
    page = (await run(browser)).text
    assert "This run failed" in page
    assert 'id="earlier-briefing"' not in page


@pytest.mark.asyncio
async def test_items_appear_in_feed_order(browser, monkeypatch):
    set_feed(monkeypatch, [
        {"id": f"item-{i}", "title": f"Item {i}", "link": f"https://example.com/item-{i}", "description": "d"}
        for i in range(1, 13)
    ])
    page = (await run(browser)).text
    assert re.findall(r"example\.com/item-(\d+)", page) == [str(i) for i in range(1, 13)]


@pytest.mark.asyncio
async def test_history_keeps_one_row_per_run_with_its_own_count(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    await run(browser)
    page = (await run(browser)).text
    rows = page.split("<tbody>")[1].split("</tr>")[:-1]
    assert len(rows) == 2
    assert re.search(r"<td>\s*0\s*</td>", rows[0])
    assert re.search(r"<td>\s*1\s*</td>", rows[1])


# ---- #22: Run Now and dates ------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_run_now_redirects_to_the_page_and_reloading_starts_no_run(raw, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    response = await raw.post("/run-now")
    assert response.status_code == 303
    assert response.headers["location"] == "/"
    assert len(get_runs()) == 1

    for _ in range(3):
        assert (await raw.get("/")).status_code == 200
    assert len(get_runs()) == 1


@pytest.mark.asyncio
async def test_refused_run_ends_on_the_page_with_its_message(raw, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    await raw.post("/run-now")
    refused = await raw.post("/run-now")
    assert refused.status_code == 303
    assert refused.headers["location"].split("?")[0] == "/"
    page = await raw.get(refused.headers["location"])
    assert page.status_code == 200
    assert "Rate limited" in page.text
    assert len(get_runs()) == 1

    plain = await raw.get("/")
    assert "Rate limited" not in plain.text


@pytest.mark.asyncio
async def test_opening_run_now_in_the_address_bar_goes_to_the_page(raw):
    response = await raw.get("/run-now")
    assert response.status_code == 303
    assert response.headers["location"] == "/"
    assert get_runs() == []


@pytest.mark.asyncio
async def test_notice_cannot_put_text_on_the_page(raw):
    page = (await raw.get("/", params={"notice": "<b>spoofed</b>"})).text
    assert "spoofed" not in page


@pytest.mark.asyncio
async def test_button_works_without_javascript(raw):
    page = (await raw.get("/")).text
    assert '<form id="run-now-form" action="/run-now" method="POST">' in page
    assert "<script" not in page


@pytest.mark.asyncio
async def test_times_read_as_a_date_with_a_timezone_and_no_microseconds(browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    page = (await run(browser)).text
    assert not re.search(r"\d{2}:\d{2}:\d{2}\.\d+", page)
    assert not re.search(r"\d{4}-\d{2}-\d{2}T", page)
    assert len(re.findall(r"[A-Z][a-z]{2} \d{1,2}, \d{4}, \d{2}:\d{2} UTC", page)) == 2  # briefing and history row


def test_format_when():
    assert app.main.format_when("2026-11-06T08:32:42.376759+00:00") == "Nov 6, 2026, 08:32 UTC"
    assert app.main.format_when("2026-11-06T14:02:42+05:30") == "Nov 6, 2026, 08:32 UTC"
    assert app.main.format_when("not a date") == "not a date"


# ---- #24: database errors --------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_error_while_starting_a_run_is_stored_and_the_next_run_works(raw, browser, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    original = app.feed.create_run

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(app.feed, "create_run", boom)
    response = await raw.post("/run-now")
    assert response.status_code == 303

    rows = get_runs()
    assert len(rows) == 1
    assert rows[0]["status"] == "failed"
    assert "database is locked" in rows[0]["error"]
    page = (await raw.get("/")).text
    assert "✗" in page and "database is locked" in page

    monkeypatch.setattr(app.feed, "create_run", original)
    assert (await run(browser)).status_code == 200
    latest = get_runs()[0]
    assert latest["status"] == "success" and latest["new_items_count"] == 1  # the lock was released


@pytest.mark.asyncio
async def test_error_during_a_run_marks_that_run_and_stores_no_partial_items(raw, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    execute("ALTER TABLE run_items RENAME TO hidden")
    assert (await raw.post("/run-now")).status_code == 303
    execute("ALTER TABLE hidden RENAME TO run_items")

    rows = get_runs()
    assert [row["status"] for row in rows] == ["failed"]  # one row, not left as running
    assert "run_items" in rows[0]["error"]
    conn = sqlite3.connect(app.db.get_db_path())
    assert conn.execute("SELECT COUNT(*) FROM items").fetchone()[0] == 0
    conn.close()


@pytest.mark.asyncio
async def test_failure_after_the_lock_cannot_leave_the_lock_held(raw, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    execute("ALTER TABLE items RENAME TO hidden")
    await raw.post("/run-now")
    execute("ALTER TABLE hidden RENAME TO items")
    conn = sqlite3.connect(app.db.get_db_path())
    assert conn.execute("SELECT COUNT(*) FROM locks").fetchone()[0] == 0
    conn.close()


@pytest.mark.asyncio
async def test_a_broken_lock_table_is_a_failure_not_a_busy_message(raw, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    execute("DROP TABLE locks")
    assert (await raw.post("/run-now")).status_code == 303
    rows = get_runs()
    assert rows[0]["status"] == "failed"
    assert "locks" in rows[0]["error"]
    assert "Another ingestion" not in rows[0]["error"]


@pytest.mark.asyncio
async def test_unwritable_database_is_logged_and_gives_a_plain_message(raw, monkeypatch, caplog):
    set_feed(monkeypatch, [ITEM])
    execute("DROP TABLE runs")

    response = await raw.post("/run-now")
    assert response.status_code == 303
    assert response.headers["location"] == "/?notice=unsaved"
    assert "Could not store a failed run" in caplog.text

    page = await raw.get("/")
    assert page.status_code == 503
    assert "unavailable" in page.text
    assert "Traceback" not in page.text and "no such table" not in page.text

    init_db()
    assert (await raw.get("/?notice=unsaved")).status_code == 200
    assert "could not be saved" in (await raw.get("/?notice=unsaved")).text


@pytest.mark.asyncio
async def test_run_held_by_the_scheduler_tells_the_visitor_and_stores_nothing(raw, monkeypatch):
    set_feed(monkeypatch, [ITEM])
    with acquire_lock("ingestion") as acquired:
        assert acquired is True
        response = await raw.post("/run-now")
    assert response.headers["location"] == "/?notice=busy"
    assert get_runs() == []
    assert "already in progress" in (await raw.get(response.headers["location"])).text


def test_error_inside_the_lock_block_reaches_the_caller_and_releases_it():
    with pytest.raises(sqlite3.OperationalError):
        with acquire_lock("ingestion") as acquired:
            assert acquired is True
            raise sqlite3.OperationalError("database is locked")
    with acquire_lock("ingestion") as again:
        assert again is True


def test_a_held_lock_refuses_a_second_holder():
    with acquire_lock("ingestion") as first:
        assert first is True
        with acquire_lock("ingestion") as second:
            assert second is False
    with acquire_lock("ingestion") as third:
        assert third is True

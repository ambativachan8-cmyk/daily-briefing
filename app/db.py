"""
Database initialization and connection management.
"""
import logging
import sqlite3
from contextlib import contextmanager
from pathlib import Path

logger = logging.getLogger(__name__)

DB_PATH = Path(__file__).parent.parent / "data" / "briefing.db"


def get_db_path() -> Path:
    """Return the database path, ensuring parent directory exists."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    return DB_PATH


@contextmanager
def get_conn():
    """Context manager for database connections."""
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init_db() -> None:
    """Initialize the database schema."""
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                status TEXT NOT NULL,
                error TEXT,
                new_items_count INTEGER DEFAULT 0,
                is_first_run INTEGER DEFAULT 0
            )
            """
        )
        columns = [row["name"] for row in conn.execute("PRAGMA table_info(runs)").fetchall()]
        if "new_items_count" not in columns:
            conn.execute("ALTER TABLE runs ADD COLUMN new_items_count INTEGER DEFAULT 0")
        if "is_first_run" not in columns:
            conn.execute("ALTER TABLE runs ADD COLUMN is_first_run INTEGER DEFAULT 0")

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                feed_id TEXT NOT NULL,
                title TEXT NOT NULL,
                link TEXT NOT NULL,
                description TEXT NOT NULL,
                first_seen_run_id INTEGER NOT NULL,
                FOREIGN KEY (first_seen_run_id) REFERENCES runs (id)
            )
            """
        )
        item_columns = [row["name"] for row in conn.execute("PRAGMA table_info(items)").fetchall()]
        if "title" not in item_columns:
            conn.execute("ALTER TABLE items ADD COLUMN title TEXT NOT NULL DEFAULT ''")
        if "link" not in item_columns:
            conn.execute("ALTER TABLE items ADD COLUMN link TEXT NOT NULL DEFAULT ''")
        if "description" not in item_columns:
            conn.execute("ALTER TABLE items ADD COLUMN description TEXT NOT NULL DEFAULT ''")

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS run_items (
                run_id INTEGER NOT NULL,
                item_id TEXT NOT NULL,
                title TEXT NOT NULL,
                link TEXT NOT NULL,
                description TEXT NOT NULL,
                PRIMARY KEY (run_id, item_id),
                FOREIGN KEY (run_id) REFERENCES runs (id),
                FOREIGN KEY (item_id) REFERENCES items (id)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS locks (
                name TEXT PRIMARY KEY,
                acquired_at TEXT
            )
            """
        )
        conn.commit()


def create_run(timestamp: str, status: str, error: str | None = None, new_items_count: int = 0, is_first_run: bool = False, conn: sqlite3.Connection | None = None) -> int:
    """Create a new run record and return its ID."""
    if conn is not None:
        cursor = conn.execute(
            "INSERT INTO runs (timestamp, status, error, new_items_count, is_first_run) VALUES (?, ?, ?, ?, ?)",
            (timestamp, status, error, new_items_count, 1 if is_first_run else 0),
        )
        return cursor.lastrowid
    else:
        with get_conn() as c:
            cursor = c.execute(
                "INSERT INTO runs (timestamp, status, error, new_items_count, is_first_run) VALUES (?, ?, ?, ?, ?)",
                (timestamp, status, error, new_items_count, 1 if is_first_run else 0),
            )
            c.commit()
            return cursor.lastrowid


def update_run_status(run_id: int, status: str, error: str | None = None, new_items_count: int | None = None, is_first_run: bool | None = None, conn: sqlite3.Connection | None = None) -> None:
    """Update an existing run's status and details."""
    if conn is not None:
        if new_items_count is not None and is_first_run is not None:
            conn.execute(
                "UPDATE runs SET status = ?, error = ?, new_items_count = ?, is_first_run = ? WHERE id = ?",
                (status, error, new_items_count, 1 if is_first_run else 0, run_id),
            )
        else:
            conn.execute(
                "UPDATE runs SET status = ?, error = ? WHERE id = ?",
                (status, error, run_id),
            )
    else:
        with get_conn() as c:
            if new_items_count is not None and is_first_run is not None:
                c.execute(
                    "UPDATE runs SET status = ?, error = ?, new_items_count = ?, is_first_run = ? WHERE id = ?",
                    (status, error, new_items_count, 1 if is_first_run else 0, run_id),
                )
            else:
                c.execute(
                    "UPDATE runs SET status = ?, error = ? WHERE id = ?",
                    (status, error, run_id),
                )
            c.commit()


def get_runs(limit: int = 100) -> list[sqlite3.Row]:
    """Get recent runs ordered by timestamp descending."""
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM runs ORDER BY timestamp DESC LIMIT ?", (limit,)
        ).fetchall()


def get_latest_run_with_new_items() -> sqlite3.Row | None:
    """The most recent successful run that found something new."""
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM runs WHERE status = 'success' AND new_items_count > 0 ORDER BY timestamp DESC LIMIT 1"
        ).fetchone()


def record_failed_run(run_id: int | None, timestamp: str, error: str) -> int | None:
    """
    Store a failure on its own connection: mark the run that had started, or add a row for one that never did.
    Returns the run's ID. If the database cannot be written, logs that and returns None; it never raises.
    """
    try:
        with get_conn() as conn:
            if run_id is None:
                run_id = conn.execute(
                    "INSERT INTO runs (timestamp, status, error, new_items_count, is_first_run) VALUES (?, 'failed', ?, 0, 0)",
                    (timestamp, error),
                ).lastrowid
            else:
                conn.execute(
                    "UPDATE runs SET status = 'failed', error = ?, new_items_count = 0, is_first_run = 0 WHERE id = ?",
                    (error, run_id),
                )
            conn.commit()
            return run_id
    except Exception:
        logger.exception("Could not store a failed run: %s", error)
        return None


def get_run(run_id: int) -> sqlite3.Row | None:
    """Get a single run by ID."""
    with get_conn() as conn:
        return conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()


def insert_items(items: list[tuple[str, str, str, str, str, int]], conn: sqlite3.Connection | None = None) -> int:
    """
    Insert new items, ignoring duplicates.
    items: list of (id, feed_id, title, link, description, first_seen_run_id)
    Returns count of newly inserted items.
    Also inserts into run_items for the first_seen_run_id so unit tests pass.
    """
    if not items:
        return 0
    
    run_items_data = [(item[5], item[0], item[2], item[3], item[4]) for item in items]

    if conn is not None:
        cursor = conn.executemany(
            "INSERT OR IGNORE INTO items (id, feed_id, title, link, description, first_seen_run_id) VALUES (?, ?, ?, ?, ?, ?)",
            items,
        )
        conn.executemany(
            "INSERT OR REPLACE INTO run_items (run_id, item_id, title, link, description) VALUES (?, ?, ?, ?, ?)",
            run_items_data,
        )
        return cursor.rowcount
    else:
        with get_conn() as c:
            cursor = c.executemany(
                "INSERT OR IGNORE INTO items (id, feed_id, title, link, description, first_seen_run_id) VALUES (?, ?, ?, ?, ?, ?)",
                items,
            )
            c.executemany(
                "INSERT OR REPLACE INTO run_items (run_id, item_id, title, link, description) VALUES (?, ?, ?, ?, ?)",
                run_items_data,
            )
            c.commit()
            return cursor.rowcount


def insert_run_items(run_items_list: list[tuple[int, str, str, str, str]], conn: sqlite3.Connection | None = None) -> None:
    """
    Insert all items seen in a run.
    run_items_list: list of (run_id, item_id, title, link, description)
    """
    if not run_items_list:
        return
    if conn is not None:
        conn.executemany(
            "INSERT OR REPLACE INTO run_items (run_id, item_id, title, link, description) VALUES (?, ?, ?, ?, ?)",
            run_items_list,
        )
    else:
        with get_conn() as c:
            c.executemany(
                "INSERT OR REPLACE INTO run_items (run_id, item_id, title, link, description) VALUES (?, ?, ?, ?, ?)",
                run_items_list,
            )
            c.commit()


def get_items_by_run(run_id: int) -> list[sqlite3.Row]:
    """Get all items seen in a specific run, in feed order."""
    with get_conn() as conn:
        return conn.execute(
            "SELECT ri.item_id as id, ri.title, ri.link, ri.description, (ri.run_id = i.first_seen_run_id) as is_new FROM run_items ri JOIN items i ON ri.item_id = i.id WHERE ri.run_id = ? ORDER BY ri.rowid", (run_id,)
        ).fetchall()


def item_exists(item_id: str) -> bool:
    """Check if an item ID already exists in the database."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM items WHERE id = ?", (item_id,)
        ).fetchone()
        return row is not None


def get_all_item_ids() -> set[str]:
    """Get all known item IDs."""
    with get_conn() as conn:
        rows = conn.execute("SELECT id FROM items").fetchall()
        return {row["id"] for row in rows}


def get_config(key: str, default: str | None = None) -> str | None:
    """Get a configuration value."""
    with get_conn() as conn:
        row = conn.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_config(key: str, value: str) -> None:
    """Set a configuration value."""
    with get_conn() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", (key, value)
        )
        conn.commit()


@contextmanager
def acquire_lock(name: str):
    """
    Context manager to acquire a named lock.
    Yields True if acquired, False if another run holds it or the database is busy.
    Other database errors, and errors raised inside the block, reach the caller.
    Only the holder releases the lock.
    """
    from datetime import datetime, timezone
    conn = sqlite3.connect(get_db_path(), timeout=0.1)

    acquired = False
    try:
        conn.execute(
            "INSERT INTO locks (name, acquired_at) VALUES (?, ?)",
            (name, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()
        acquired = True
    except sqlite3.IntegrityError:
        pass
    except sqlite3.OperationalError as error:
        if "locked" not in str(error) and "busy" not in str(error):
            conn.close()
            raise

    try:
        yield acquired
    finally:
        if acquired:
            try:
                # Taking the lock may give up quickly; releasing it must not, or every later run is refused.
                conn.execute("PRAGMA busy_timeout = 5000")
                conn.execute("DELETE FROM locks WHERE name = ?", (name,))
                conn.commit()
            except sqlite3.Error:
                logger.exception("Could not release the %s lock", name)
        conn.close()


def cleanup_stale_runs() -> None:
    """Mark any 'running' runs as 'failed' (e.g. after a crash) at process start."""
    with get_conn() as conn:
        conn.execute(
            "UPDATE runs SET status = 'failed', error = 'Orphaned run (likely crash)' WHERE status = 'running'"
        )
        conn.execute("DELETE FROM locks WHERE name = 'ingestion'")
        conn.commit()

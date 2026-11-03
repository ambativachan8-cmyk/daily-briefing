"""
Database initialization and connection management.
"""
import sqlite3
from contextlib import contextmanager
from pathlib import Path

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
                error TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                feed_id TEXT NOT NULL,
                first_seen_run_id INTEGER NOT NULL,
                FOREIGN KEY (first_seen_run_id) REFERENCES runs (id)
            )
            """
        )
        conn.commit()


def create_run(timestamp: str, status: str, error: str | None = None) -> int:
    """Create a new run record and return its ID."""
    with get_conn() as conn:
        cursor = conn.execute(
            "INSERT INTO runs (timestamp, status, error) VALUES (?, ?, ?)",
            (timestamp, status, error),
        )
        conn.commit()
        return cursor.lastrowid


def update_run_status(run_id: int, status: str, error: str | None = None) -> None:
    """Update an existing run's status and error."""
    with get_conn() as conn:
        conn.execute(
            "UPDATE runs SET status = ?, error = ? WHERE id = ?",
            (status, error, run_id),
        )
        conn.commit()


def get_runs(limit: int = 100) -> list[sqlite3.Row]:
    """Get recent runs ordered by timestamp descending."""
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM runs ORDER BY timestamp DESC LIMIT ?", (limit,)
        ).fetchall()


def get_run(run_id: int) -> sqlite3.Row | None:
    """Get a single run by ID."""
    with get_conn() as conn:
        return conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()


def insert_items(items: list[tuple[str, str, int]]) -> int:
    """
    Insert new items, ignoring duplicates.
    items: list of (id, feed_id, first_seen_run_id)
    Returns count of newly inserted items.
    """
    if not items:
        return 0
    with get_conn() as conn:
        cursor = conn.executemany(
            "INSERT OR IGNORE INTO items (id, feed_id, first_seen_run_id) VALUES (?, ?, ?)",
            items,
        )
        conn.commit()
        return cursor.rowcount


def get_items_by_run(run_id: int) -> list[sqlite3.Row]:
    """Get all items first seen in a specific run."""
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM items WHERE first_seen_run_id = ?", (run_id,)
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
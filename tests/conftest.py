"""
No test can reach the app's real database.

The default path is replaced as soon as pytest loads this file, before any test module runs, and
every test then gets its own empty file. The suite once emptied data/briefing.db (issue #23).
"""
import tempfile
from pathlib import Path

import pytest

import app.db

_session_dir = tempfile.TemporaryDirectory(prefix="briefing-tests-")
app.db.DB_PATH = Path(_session_dir.name) / "session.db"


@pytest.fixture(autouse=True)
def isolated_database(tmp_path, monkeypatch):
    monkeypatch.setattr(app.db, "DB_PATH", tmp_path / "test.db")

"""
Every test gets its own empty database. See tests/__init__.py for why none can reach the real one.
"""
import pytest

import app.db


@pytest.fixture(autouse=True)
def isolated_database(tmp_path, monkeypatch):
    monkeypatch.setattr(app.db, "DB_PATH", tmp_path / "test.db")

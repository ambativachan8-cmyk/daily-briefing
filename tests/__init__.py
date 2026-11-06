"""
No test can reach the app's real database (issue #23: the suite once emptied data/briefing.db).

Python runs this file before any test module or conftest in the package, so the default path is
already gone by the time anything can open it, even with pytest --noconftest.
"""
import tempfile
from pathlib import Path

import app.db

_session_dir = tempfile.TemporaryDirectory(prefix="briefing-tests-")
app.db.DB_PATH = Path(_session_dir.name) / "session.db"

"""Tests for the agent observability report (operator tooling; lives outside the product tests/)."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_observability as ao  # noqa: E402

RUNS = [
    {"ts": "20261102T100000Z", "agent": "manager", "framework": "hermes", "issue": "", "exit": 0,
     "provider": "gemini", "model": "flash", "total_tokens": 1000},
    {"ts": "20261102T110000Z", "agent": "backend", "framework": "openclaw", "issue": "2", "status": "error",
     "provider": "google", "model": "lite", "total_tokens": None},
    {"ts": "20261102T120000Z", "agent": "backend", "framework": "openclaw", "issue": "2", "status": "error",
     "provider": "google", "model": "lite", "total_tokens": None},
    {"ts": "20261102T130000Z", "agent": "backend", "framework": "openclaw", "issue": "2", "status": "ok",
     "provider": "nvidia", "model": "nemotron", "total_tokens": None},
    {"ts": "20261102T140000Z", "agent": "reviewer", "framework": "hermes", "issue": "2", "exit": 2,
     "provider": "gemini", "model": "flash", "total_tokens": 500},
    {"ts": "20261102T150000Z", "agent": "tester", "framework": "openclaw", "issue": "2"},
]


def test_outcome_rules():
    assert [ao.outcome(r) for r in RUNS] == ["success", "failure", "failure", "success", "failure", "unknown"]


def test_summaries_and_success_rate():
    by_agent = {d["name"]: d for d in ao.summarize(RUNS, lambda r: r.get("agent"))}
    assert by_agent["backend"]["attempts"] == 3 and by_agent["backend"]["success_rate"] == 33.3
    assert by_agent["tester"]["unknown"] == 1 and by_agent["tester"]["success_rate"] is None
    assert by_agent["manager"]["tokens_per_success"] == 1000


def test_ticket_retries_and_streaks():
    t = {d["issue"]: d for d in ao.tickets(RUNS)}
    assert t["2"]["attempts"] == 5 and t["2"]["retries"] == 4 and t["2"]["span_hours"] == 4.0
    streak = ao.failure_streaks(RUNS)[0]
    assert streak["agent"] == "backend" and streak["length"] == 2 and streak["providers"] == ["google"]


def test_report_end_to_end(tmp_path):
    src = tmp_path / "runs.jsonl"
    src.write_text("\n".join(json.dumps(r) for r in RUNS), encoding="utf-8")
    out = tmp_path / "report.md"
    assert ao.main(["x", str(src), str(out)]) == 0
    text = out.read_text(encoding="utf-8")
    assert "6 agent attempts" in text and "## By ticket" in text and "| backend |" in text


def test_real_run_log_parses():
    real = Path(__file__).resolve().parent.parent / "docs" / "evidence" / "runs.jsonl"
    rows = ao.load(real)
    assert len(rows) == 176
    assert all(ao.outcome(r) in ("success", "failure", "unknown") for r in rows)

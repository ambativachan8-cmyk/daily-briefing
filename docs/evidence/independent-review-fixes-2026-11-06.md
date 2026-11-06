> Reports by a fresh reviewer of PR #27, told to falsify it, given the issues, the diff and the brief. Launched by the operator on the operator's machine, so separate, not third-party. Copied unedited below this note. What was done about each finding is in [../RELEASE_EVIDENCE.md](../RELEASE_EVIDENCE.md) and DELIVERY section 6.

# First report, at `2e058e3`

**Review of `fix/issues-21-24` at `2e058e3`.** I ran everything on my own copies. The worktree is untouched and no servers are left running.

**Baseline:** 91 tests pass, A1–A8 pass, and `mutate.py` killed 52 of 52.

**Done-when lists**
- **#21:** all met over HTTP, including 12 items in order, the earlier briefing and one history row per run.
- **#22:** all met: 303 to `/`, reloads start no run, refusal message shown, `Nov 6, 2026, 09:06 UTC`, no script.
- **#23:** seeded rows stayed byte-identical from root, `tests/` and outside. All listed mutants were killed, the overlap removal in 6.7s. One item is only partly met (test finding 3).
- **#24:** three items fail in edge cases. Renamed or dropped tables and a read-only file all behaved correctly.

**Defects (all low to medium for a prototype)**
1. **Lock stays held (#24, medium-low).** With a trigger aborting `DELETE FROM locks`, the run succeeds but the lock row stays. After I removed the trigger, every Run Now said "busy" and stored no row until restart. By the code, scheduler ticks skip too. Fix: on acquire, delete locks older than 10 minutes.
2. **Unhandled 500 (#24).** With `data` replaced by a file, `/` and `/runs` return 500 from `FileExistsError`. A dangling `data` symlink should hit the same path (not run). Fix: register the handler for `OSError` too.
3. **Locked database (#24).** With another process holding the write lock, Run Now says "Another run is in progress", with no row and 0 log lines. Fix: log a warning in that branch.
4. **Lost failure.** With commit of the `running` row made to fail (simulated), the result has `run_id=1` but 0 rows and no "unsaved" notice. `record_failed_run`'s UPDATE matches nothing. Fix: INSERT when rowcount is 0.
5. **Stuck `running` row.** If the UPDATE on `runs` also fails, the row stays `running` until restart, and the page says "Nothing has changed". Fix: add a template branch for `running`.
6. **Removed database file.** The page returns 503 and runs never recover until restart, because tables aren't recreated. Fix: call `init_db()` in the failure path.
7. **Timestamp ties.** Ties return oldest first (`[1,2,3]`), and a backward clock step hides the newest run. Fix: add `, id DESC` to both queries.

**Held**
- 150 parallel Run Nows with a 1s scheduler gave 157 successes, 0 `running`, no lock left and 12 items once.
- A late failure rolled back to 0 items, and the next run found 12 new.
- `notice` is whitelisted, and feed text is escaped.
- `format_when` converts offsets correctly. Naive strings are read as local time, but the app stores none.
- `/ingest` and `/runs` JSON responses looked right; those handlers' responses are unchanged in the diff.

**Tests that cannot fail for their stated reason**
1. **`test_error_during_a_run_..._no_partial_items`:** adding `conn.commit()` after `insert_items` passes 91/91, yet that mutant keeps 12 items under a failed run and the next run reports 0 new. The rename fails inside `insert_items`, before that commit. Fix: fail at the final `update_run_status`.
2. **`test_feed_text_is_escaped_on_the_page`:** `|safe` on the earlier briefing's title or description passes 91/91, because only a first run is rendered. Fix: repeat it after a quiet run.
3. **`test_scheduler.py`:** "7" is never asserted. Ignoring the interval passes all 4 tests there, and only `test_coverage_gaps` catches it. Fix: assert the sleep argument.
4. **Lock-release failure:** untested. Removing its `except` passes 91/91.
5. **`--noconftest`:** this explicit opt-out wrote to the seeded database (5 rows to 10). Fix: move the redirect to `tests/__init__.py`.

Outside the root, 33 tests fail on the relative `templates` path, which base also uses. Rows are unchanged.

**`verify_pr.sh`**
- **The gaming route works.** A candidate placing `<i id="earlier-briefing">` above old items labelled new in the quiet branch passes all six steps; the old line would have counted 6, 6, 5, 5. A1 and A4 still bind.
- **Judgement: negligible weakening.** It takes deliberate code, the template is candidate-controlled, and a single-quoted `href` should evade the old grep too (not run). The old line cannot stay, because an honest quiet page shows 3 links.
- **Existing gap.** With dedup off, all six steps pass on both lines, because the template filters on `is_new`.
- **Smallest fix (not run).** Also check the newest `new_items_count` from `/runs` in `feed_run`; this should catch both cases.

# Retest, at `4247ae1`

**Retest of `4247ae1` on a fresh copy.** 98 tests pass, A1–A8 pass, and the harness killed 62 of 62. The worktree is clean and no servers are running.

**Defects**
- **1, fixed:** a lock aged 9 minutes still refuses; aged 11 minutes (backdated) the run succeeds. Recovery can take 10 minutes.
- **2, fixed:** `/` and `/runs` return plain 503. The symlink variant couldn't be created here.
- **3, fixed:** a warning is logged. The visitor still sees "Another run is in progress".
- **4, fixed:** the simulated commit failure stores one failed row.
- **5, fixed:** the page says "This run has not finished."
- **7, ties fixed:** order is `[5,3,2,1]`. A backward clock step still hides the newest run; my suggested fix never covered that. Low.

**Tests**
- **Findings 1–4, fixed:** all those mutants are now killed.
- **Finding 5, fixed:** the seeded database hash is unchanged under `--noconftest`, importlib mode, `tests/` and outside. The last two now pass 98.

**Gate (emulated with Python for `jq`)**
- **Dedup-off, closed:** `/runs` gives 3, 3, 4, 3, 4 against wanted 0, 0, 1, 0, 0.
- **Marker, still open:** all steps pass, because `/runs` is truthful there. My "catch both" was wrong. It still takes deliberate code.

**Defect 6:** I agree with leaving it. My `init_db()` suggestion would fake a first run. A restart still does that (run 1, 12 new), but only after a human acts.

**New code**
- **Stale-lock delete:** no defect. A live lock survives, and a failed insert rolls back. Age mutants (60s, 1 day) survive, so 600 is untested.
- **UPDATE-then-INSERT:** no defect, one row per failure. It could only hit another run's reused ID with a second writer, and deploy uses one worker.

**Pre-existing, seen here:** `/ingest` returns the absolute filesystem path in `error` on `OSError`. Low.

"""Mutation test: break the product one way at a time in a throwaway copy; the suite should fail.
Usage: python mutate.py <clean checkout> <empty work dir> <python with requirements installed>
A mutant that is NOT-APPLIED means the source moved on; it proves nothing either way."""
import shutil,subprocess,sys,os,re,json
SRC=sys.argv[1]; WORK=sys.argv[2]; PY=sys.argv[3]
M=[
("dedup off: every item new","app/feed.py","known_ids = get_all_item_ids()","known_ids = set()"),
("id from title not feed id/link","app/feed.py","""    if "id" in item and item["id"]:
        return str(item["id"])
    link = item.get("link", "")
    return hashlib.sha256(link.encode()).hexdigest()[:16]""","""    return hashlib.sha256(item.get("title","").encode()).hexdigest()[:16]"""),
("first-run mark never set","app/feed.py","is_first_run = len(known_ids) == 0","is_first_run = False"),
("failed run saved as success","app/feed.py",'update_run_status(run_id, "failed", error, new_items_count=0, is_first_run=False, conn=conn)','update_run_status(run_id, "success", None, new_items_count=0, is_first_run=False, conn=conn)'),
("fail switch never consumed","app/feed.py","should_fail = _consume_feed_fail_config(conn=conn) if consume_config else _check_feed_fail_config(conn=conn)","should_fail = _check_feed_fail_config(conn=conn)"),
("rate limit off","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 0"),
("rate limit weak (5s)","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 5"),
("rate limit weak (59s)","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 59"),
("rate limit weak (1s)","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 1"),
("/ingest not rate limited","app/main.py","""    allowed, retry_after = check_rate_limit(client_ip)
    if not allowed:
        return JSONResponse(""","""    allowed, retry_after = True, None
    if not allowed:
        return JSONResponse("""),
("Run now button does nothing","app/main.py","""        result = await ingest_feed()
    finally:
        _run_now_lock = False

    if result.get""","""        result = {"status": "success", "run_id": 1}
    finally:
        _run_now_lock = False

    if result.get"""),
("overlap flag never set on run-now","app/main.py","""    _run_now_lock = True
    try:
        result = await ingest_feed()
    finally:""","""    try:
        result = await ingest_feed()
    finally:"""),
("overlap flag never checked on run-now","app/main.py","""    if _run_now_lock:
        return _back_to_page("busy")""","""    if False:
        return _back_to_page("busy")"""),
("latest run is oldest","app/db.py",'"SELECT * FROM runs ORDER BY timestamp DESC, id DESC LIMIT ?"','"SELECT * FROM runs ORDER BY timestamp ASC, id ASC LIMIT ?"'),
("same-time runs oldest first","app/db.py",'ORDER BY timestamp DESC, id DESC LIMIT ?"','ORDER BY timestamp DESC, id ASC LIMIT ?"'),
("db lock ignored","app/feed.py","            if not acquired:\n","            if False:\n"),
("stale cleanup no-op","app/db.py","""        conn.execute(
            "UPDATE runs SET status = 'failed', error = 'Orphaned run (likely crash)' WHERE status = 'running'"
        )""","""        pass"""),
("scheduler never started","app/main.py","    start_scheduler()\n","    pass\n"),
("scheduler dies after first error","app/scheduler.py","""            logger.error(f"Error in scheduler tick: {e}", exc_info=True)""","""            raise"""),
("scheduler stops after first tick","app/scheduler.py","""        try:
            await asyncio.sleep(interval)""","""        return
        try:
            await asyncio.sleep(interval)"""),
("scheduler ignores its interval","app/scheduler.py","await asyncio.sleep(interval)","await asyncio.sleep(3600)"),
("page lists old items too","templates/index.html","{% for item in latest_items %}\n            {% if item.is_new %}","{% for item in latest_items %}\n            {% if true %}"),
("page drops item link","templates/index.html",'<div class="new-item">\n                <a href="{{ item.link }}" target="_blank">{{ item.title }}</a>','<div class="new-item">\n                <span>{{ item.title }}</span>'),
("page shows no date","templates/index.html","{{ latest_run.timestamp|when }} · ","· "),
("history marks failure as tick","templates/index.html",'<span class="status-failed">✗</span>','<span class="status-failed">✓</span>'),
("history hides new count","templates/index.html","<td>{{ run.new_items_count }}</td>","<td></td>"),
("first-run badge dropped from the briefing heading","templates/index.html",'<span class="first-run-badge">first run</span>',''),
("title rendered unescaped (XSS)","templates/index.html",'<div class="new-item">\n                <a href="{{ item.link }}" target="_blank">{{ item.title }}</a>','<div class="new-item">\n                <a href="{{ item.link }}" target="_blank">{{ item.title|safe }}</a>'),
("#21 first-run sentence removed","templates/index.html",'<p class="first-run-note">This is the first run: there was nothing to compare with, so everything is new.</p>',''),
("#21 earlier briefing never shown","templates/index.html","{% if earlier_run %}","{% if false %}"),
("#21 earlier briefing not labelled","templates/index.html","<h2>Earlier Briefing</h2>",""),
("#21 earlier briefing lists every item seen","templates/index.html","{% for item in earlier_items %}\n            {% if item.is_new %}","{% for item in earlier_items %}\n            {% if true %}"),
("#21 earlier briefing is the oldest","app/db.py","new_items_count > 0 ORDER BY timestamp DESC, id DESC LIMIT 1","new_items_count > 0 ORDER BY timestamp ASC, id ASC LIMIT 1"),
("#21 earlier briefing unescaped title","templates/index.html",'''<div class="earlier-item">
                <a href="{{ item.link }}" target="_blank">{{ item.title }}</a>''','''<div class="earlier-item">
                <a href="{{ item.link }}" target="_blank">{{ item.title|safe }}</a>'''),
("#21 earlier briefing unescaped description","templates/index.html",'''<a href="{{ item.link }}" target="_blank">{{ item.title }}</a>
                <div class="description">{{ item.description }}</div>
            </div>
            {% endif %}
            {% endfor %}
        </div>
    </div>''','''<a href="{{ item.link }}" target="_blank">{{ item.title }}</a>
                <div class="description">{{ item.description|safe }}</div>
            </div>
            {% endif %}
            {% endfor %}
        </div>
    </div>'''),
("#21 unfinished run called quiet","templates/index.html","{% elif latest_run.status == 'running' %}","{% elif false %}"),
("#21 earlier briefing hidden after a failed run","app/main.py","""    if latest_run and not latest_run["new_items_count"]:""","""    if latest_run and latest_run["status"] == "success" and not latest_run["new_items_count"]:"""),
("#21 quiet line removed","templates/index.html","No new items in this run. Nothing has changed since the last one.",""),
("#21 items not in feed order","app/db.py"," WHERE ri.run_id = ? ORDER BY ri.rowid"," WHERE ri.run_id = ?"),
("#22 redirect keeps the POST","app/main.py","status_code=303)","status_code=307)"),
("#22 no way back from the address bar","app/main.py",'@app.get("/run-now")','@app.get("/run-now-disabled")'),
("#22 refusal message lost","app/main.py",'return _back_to_page("rate-limited")','return _back_to_page()'),
("#22 notice reflects the URL","app/main.py",'"notice": NOTICES.get(notice),','"notice": notice,'),
("#22 raw ISO in the history","templates/index.html","<td>{{ run.timestamp|when }}</td>","<td>{{ run.timestamp }}</td>"),
("#22 raw ISO in the briefing","templates/index.html","{{ latest_run.timestamp|when }}","{{ latest_run.timestamp }}"),
("#22 time without a timezone","app/main.py"," UTC\"","\""),
("#22 script intercepts the form","templates/index.html","</body>","<script>document.forms[0].addEventListener('submit',e=>e.preventDefault())</script></body>"),
("#24 failure not stored","app/feed.py",'"run_id": record_failed_run(run_id, timestamp, str(e)),','"run_id": run_id,'),
("#24 failure re-raised","app/feed.py",'        logger.exception("Run failed")','        raise'),
("#24 failed start adds no row","app/db.py","""            if not updated:  # it never started, or its row was never committed
""","""            if False:
"""),
("#24 failed run left as running","app/db.py","UPDATE runs SET status = 'failed', error = ?, new_items_count = 0, is_first_run = 0 WHERE id = ?","UPDATE runs SET status = 'running', error = ?, new_items_count = 0, is_first_run = 0 WHERE id = ?"),
("#24 a failed run keeps its partial items","app/feed.py","""                    insert_items(new_items, conn=conn)
""","""                    insert_items(new_items, conn=conn)
                    conn.commit()
"""),
("#24 lock release failure raises","app/db.py","""            except sqlite3.Error:
                logger.exception("Could not release the %s lock", name)""","""            except ZeroDivisionError:
                pass"""),
("#24 left-behind lock never expires","app/db.py","""            "DELETE FROM locks WHERE name = ? AND acquired_at < ?",""","""            "DELETE FROM locks WHERE name = ? AND acquired_at < '0' AND acquired_at < ?","""),
("#24 a recent lock is taken over","app/db.py","LOCK_MAX_AGE_SECONDS = 600","LOCK_MAX_AGE_SECONDS = -600"),
("#24 lock expires after a minute","app/db.py","LOCK_MAX_AGE_SECONDS = 600","LOCK_MAX_AGE_SECONDS = 60"),
("#24 lock lasts a day","app/db.py","LOCK_MAX_AGE_SECONDS = 600","LOCK_MAX_AGE_SECONDS = 86400"),
("#24 busy database not logged","app/db.py","""        logger.warning("Database busy, could not take the %s lock: %s", name, error)""","""        pass"""),
("#24 unreachable path gives a raw 500","app/main.py","@app.exception_handler(OSError)\n",""),
("#24 storing a failure can raise","app/db.py","""    except Exception:
        logger.exception("Could not store a failed run: %s", error)
        return None""","""    except ZeroDivisionError:
        return None"""),
("#24 lock never released","app/db.py","""                conn.execute("DELETE FROM locks WHERE name = ?", (name,))
""","""                pass
"""),
("#24 every lock error reads as busy","app/db.py","""        if "locked" not in str(error) and "busy" not in str(error):""","""        if False:"""),
("#24 unreadable page gives a raw 500","app/main.py","@app.exception_handler(sqlite3.Error)\n",""),
("#24 scheduler overlap not reported","app/feed.py",'                    "skipped": True,\n',''),
]
res=[]
for name,f,old,new in M:
    shutil.rmtree(WORK,ignore_errors=True)
    shutil.copytree(SRC,WORK,ignore=shutil.ignore_patterns('.git','.venv','data','__pycache__','.pytest_cache'))
    p=os.path.join(WORK,f); t=open(p,encoding='utf8',newline='').read().replace('\r\n','\n')
    if old not in t: res.append((name,'NOT-APPLIED','')); print('NOT-APPLIED',name,flush=True); continue
    open(p,'w',encoding='utf8',newline='').write(t.replace(old,new,1))
    try:
        r=subprocess.run([PY,'-m','pytest','-q','-x','-p','no:cacheprovider','-W','ignore'],cwd=WORK,capture_output=True,text=True,timeout=60,env={**os.environ,'PYTHONUTF8':'1'})
        tail=[l for l in r.stdout.splitlines() if l.strip()][-1] if r.stdout.strip() else ''
        verdict='KILLED' if r.returncode else 'SURVIVED'
    except subprocess.TimeoutExpired:
        verdict='HUNG';tail='timeout 60s'
    res.append((name,verdict,tail)); print(verdict,'|',name,'|',tail[:90],flush=True)
s=sum(1 for r in res if r[1]=='SURVIVED'); print(f'mutants={len(res)} survived={s} hung={sum(r[1]=="HUNG" for r in res)} notapplied={sum(r[1]=="NOT-APPLIED" for r in res)}')

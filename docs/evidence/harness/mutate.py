"""Mutation test: break the product one way at a time in a throwaway copy; the suite should fail.
Usage: python mutate.py <clean checkout> <empty work dir> <python with requirements installed>
A mutant that is NOT-APPLIED means the source moved on; it proves nothing either way."""
import shutil,subprocess,sys,os,re,json
SRC=sys.argv[1]; WORK=sys.argv[2]; PY=sys.argv[3]
M=[
("dedup off: every item new","app/feed.py","known_ids = get_all_item_ids()","known_ids = set()"),
("id from title not feed id/link","app/feed.py",'''    if "id" in item and item["id"]:
        return str(item["id"])
    link = item.get("link", "")
    return hashlib.sha256(link.encode()).hexdigest()[:16]''','''    return hashlib.sha256(item.get("title","").encode()).hexdigest()[:16]'''),
("first-run mark never set","app/feed.py","is_first_run = len(known_ids) == 0","is_first_run = False"),
("failed run saved as success","app/feed.py",'update_run_status(run_id, "failed", error, new_items_count=0, is_first_run=False, conn=conn)','update_run_status(run_id, "success", None, new_items_count=0, is_first_run=False, conn=conn)'),
("fail switch never consumed","app/feed.py","should_fail = _consume_feed_fail_config(conn=conn) if consume_config else _check_feed_fail_config(conn=conn)","should_fail = _check_feed_fail_config(conn=conn)"),
("rate limit off","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 0"),
("rate limit weak (5s)","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 5"),
("Run now button does nothing","app/main.py","        await ingest_feed()\n        # Return updated page","        pass\n        # Return updated page"),
("overlap flag never checked on run-now","app/main.py","    _run_now_lock = True\n    try:\n        await ingest_feed()","    try:\n        await ingest_feed()"),
("latest run is oldest","app/db.py",'"SELECT * FROM runs ORDER BY timestamp DESC LIMIT ?"','"SELECT * FROM runs ORDER BY timestamp ASC LIMIT ?"'),
("db lock always granted","app/db.py","""    except (sqlite3.IntegrityError, sqlite3.OperationalError):
        yield False""","""    except (sqlite3.IntegrityError, sqlite3.OperationalError):
        yield True"""),
("stale cleanup no-op","app/db.py","""        conn.execute(
            "UPDATE runs SET status = 'failed', error = 'Orphaned run (likely crash)' WHERE status = 'running'"
        )""","""        pass"""),
("scheduler never started","app/main.py","    start_scheduler()\n","    pass\n"),
("scheduler dies after first error","app/scheduler.py","""            logger.error(f"Error in scheduler tick: {e}", exc_info=True)""","""            raise"""),
("page lists old items too","templates/index.html","{% if item.is_new %}","{% if true %}"),
("page drops item link","templates/index.html",'<a href="{{ item.link }}" target="_blank">{{ item.title }}</a>','<span>{{ item.title }}</span>'),
("page shows no date","templates/index.html","Date: {{ latest_run.timestamp }} | ","Date: | "),
("history marks failure as tick","templates/index.html",'<span class="status-failed">✗</span>','<span class="status-failed">✓</span>'),
("history hides new count","templates/index.html","<td>{{ run.new_items_count }}</td>","<td></td>"),
("first-run badge dropped from the briefing heading","templates/index.html",'<span class="first-run-badge">first run</span>',''),
("rate limit weak (1s)","app/main.py","RATE_LIMIT_SECONDS = 60","RATE_LIMIT_SECONDS = 1"),
("/ingest not rate limited","app/main.py","""    allowed, retry_after = check_rate_limit(client_ip)
    if not allowed:
        return JSONResponse(""","""    allowed, retry_after = True, None
    if not allowed:
        return JSONResponse("""),
("scheduler stops after first tick","app/scheduler.py","""        try:
            await asyncio.sleep(interval)""","""        return
        try:
            await asyncio.sleep(interval)"""),
("scheduler ignores its interval","app/scheduler.py","await asyncio.sleep(interval)","await asyncio.sleep(3600)"),
("title rendered unescaped (XSS)","templates/index.html",'{{ item.title }}</a>','{{ item.title|safe }}</a>'),
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

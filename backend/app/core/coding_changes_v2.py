"""EXPERIMENT (isolated copy only): commit-safe change feed for coding_records.

Cursor "tx:id" like transactions. Company-wide across categories (the client splits by the
`category` field). Reads are not branch-filtered anywhere in /coding (branch checks are on writes
only), so a record cannot leave a reader's visibility by a branch change: it just comes back updated.
Requires migration 002 (coding_records.tx). Cost fields are projected by the caller's cost right at
serve time, and that right is part of the scope fingerprint."""
from sqlalchemy import text, select
from app.core.changes_v2 import parse_cursor, MAX_ID, bootstrap_cursor  # same cursor rules
from app.core.models import CodingRecord

SQL = text("""
with w as (select pg_snapshot_xmin(pg_current_snapshot()) wm, pg_snapshot_xmax(pg_current_snapshot()) xm)
select t.id, t.tx::text as tx, w.wm::text as wm, w.xm::text as xm
from w left join lateral (
  select x.id, x.tx from coding_records x
  where x.company_code = :company and (x.tx, x.id) > (CAST(CAST(:ctx AS text) AS xid8), :cid) and x.tx < w.wm
  order by x.tx, x.id limit :lim) t on true
""")

async def fetch(db, company, cursor, limit, serialize):
    ctx, cid = parse_cursor(cursor)
    res = await db.execute(SQL, {"company": company, "ctx": str(ctx), "cid": cid, "lim": limit + 1})
    rows = res.mappings().all()
    wm, xm = int(rows[0]["wm"]), int(rows[0]["xm"])
    if ctx >= xm:
        return {"invalid": True, "items": [], "next_cursor": cursor, "has_more": False}
    rows = [r for r in rows if r["id"] is not None]
    more = len(rows) > limit
    rows = rows[:limit]
    ids = [r["id"] for r in rows]
    docs = {}
    if ids:
        for d in (await db.execute(select(CodingRecord).where(CodingRecord.id.in_(ids)))).scalars().all():
            docs[d.id] = d
    items = [serialize(docs[i]) for i in ids if i in docs]
    nxt = f"{int(rows[-1]['tx'])}:{rows[-1]['id']}" if more else f"{wm - 1}:{MAX_ID}"
    return {"invalid": False, "items": items, "next_cursor": nxt, "has_more": more}

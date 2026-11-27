# backend/app/core/changes_v2.py
"""EXPERIMENT (isolated copy only): commit-safe change feed for transactions.

Cursor is "tx:id" (xid8 of the writing transaction, row id). A page returns only rows whose
transaction is finished (tx < snapshot xmin). Rows that left the caller's branches come back
as tombstones with identifiers only (no payload, no current branch)."""


# خطأ بيتبعت لما فيد التغييرات لسه ما اتطبقش على قاعدة البيانات
class FeedNotApplied(RuntimeError):
    """A v2 feed's migration has not been applied (or failed) on this database. The endpoint
    handler answers the "disabled" fallback instead of HTTP 500."""


from sqlalchemy import text, bindparam, String
from sqlalchemy.exc import DBAPIError
from sqlalchemy.dialects.postgresql import ARRAY

# أقصى قيمة لرقم السجل (int4) تُستخدم كحد أعلى للمؤشر
MAX_ID = 2 ** 31 - 1  # transactions.id is int4

SQL = text("""
with w as (select pg_snapshot_xmin(pg_current_snapshot()) wm, pg_snapshot_xmax(pg_current_snapshot()) xm)
select t.id, t.branch_code, t.serial, t.touched, t.tx::text as tx, w.wm::text as wm, w.xm::text as xm, t.row_json
from w left join lateral (
  select x.id, x.branch_code, x.serial, x.touched, x.tx, to_jsonb(x) as row_json from transactions x
  where x.company_code = :company and (x.tx, x.id) > (CAST(CAST(:ctx AS text) AS xid8), :cid) and x.tx < w.wm
    and (:all_branches or x.touched && CAST(:allowed AS text[]))
  order by x.tx, x.id limit :lim) t on true
""").bindparams(bindparam("allowed", type_=ARRAY(String)))


# يحلّل مؤشر التزامن (cursor) النصي إلى أرقام ويتحقق منه
def parse_cursor(c: str):
    a, b = (c or "0:0").split(":")
    return int(a), int(b)


# يجيب التغييرات الجديدة للمعاملات بعد المؤشر مع مراعاة الشركة والفروع المسموحة
async def fetch(db, company, allowed, cursor, limit, serialize):
    ctx, cid = parse_cursor(cursor)
    res = await db.execute(SQL, {"company": company, "ctx": str(ctx), "cid": cid, "lim": limit + 1,
                                 "all_branches": not allowed, "allowed": list(allowed or [])})
    rows = res.mappings().all()
    wm, xm = int(rows[0]["wm"]), int(rows[0]["xm"])
    if ctx >= xm:
        return {"invalid": True, "items": [], "next_cursor": cursor, "has_more": False}
    rows = [r for r in rows if r["id"] is not None]
    more = len(rows) > limit
    rows = rows[:limit]
    items = []
    for r in rows:
        if not allowed or r["branch_code"] in allowed:
            items.append(serialize(r))
        else:
            for b in sorted(set(r["touched"] or []) & set(allowed)):
                items.append({"id": r["id"], "company_code": company, "branch_code": b,
                              "serial": r["serial"], "action": "delete", "tombstone": True})
    nxt = f"{int(rows[-1]['tx'])}:{rows[-1]['id']}" if more else f"{wm - 1}:{MAX_ID}"
    return {"invalid": False, "items": items, "next_cursor": nxt, "has_more": more}


# يرجّع مؤشر البداية الحالي لفيد التغييرات
async def bootstrap_cursor(db):
    r = await db.execute(text("select pg_snapshot_xmin(pg_current_snapshot())::text"))
    return f"{int(r.scalar()) - 1}:{MAX_ID}"


# يحسب بصمة نطاق الصلاحيات عشان العميل يعرف لو النطاق اتغير
async def scope_fingerprint(db, feed, company, allowed):
    """The scope fingerprint the changes-v2 endpoints stamp on their responses, computed in
    this one place so other surfaces (session-profile) return the identical value."""
    import zlib
    epoch = await feed_epoch(db, feed)
    return str(zlib.crc32((company + "|" + ",".join(sorted(allowed or ["*"])) + "|epoch=" + epoch).encode()))


# يقرأ رقم حقبة (epoch) الفيد أو يرفع خطأ لو الفيد غير مطبّق
async def feed_epoch(db, feed):
    """Random value written by the migration each time the feed is (re)applied. Part of the scope
    fingerprint: after a rollback and re-apply, old client cursors are refused instead of skipping
    changes that were never stamped. Raises FeedNotApplied when the feed (or its table) is missing."""
    try:
        r = await db.execute(text("select epoch from feed_epoch where feed = :f"), {"f": feed})
        v = r.scalar()
    except DBAPIError as exc:
        # 42P01: the feed_epoch table itself does not exist before the migration runs
        if getattr(getattr(exc, "orig", None), "sqlstate", None) == "42P01":
            raise FeedNotApplied("feed epoch missing: migration not applied") from exc
        raise
    if v is None:
        raise FeedNotApplied("feed epoch missing: migration not applied")
    return str(v)

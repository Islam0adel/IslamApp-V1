"""EXPERIMENT (isolated copy only): generic commit-safe feed for a table that has tx xid8 and
left_branches text[] (migration 00N). Same cursor/watermark rule as transactions/coding/employees.
Rows are filtered with the caller's visibility clause; a row that LEFT the caller's branches comes
back as an identifier-only removal built by `tomb` (never the payload)."""
from sqlalchemy import select, text, or_, bindparam, String, Text, cast, literal_column
from sqlalchemy.dialects.postgresql import ARRAY
from app.core.changes_v2 import parse_cursor, MAX_ID


STR_DONE = ""  # string-id cursor "tx:" = every row with tx <= that value was delivered (no id bound)


def parse_cursor_str(c):
    """String-id cursor: "tx:" (whole tx done) or "tx:i<id>" (resume after that id; any id text, even empty or '~')."""
    a, b = (c or "0:").split(":", 1)
    if b and not b.startswith("i"):
        raise ValueError("bad cursor")
    return int(a), (None if b == "" else b[1:])


async def fetch(db, Model, table, company, cursor, limit, visibility, allowed_branches, serialize, tomb, str_id=False):
    """str_id=True: String primary key (sales, returns, customer payments); ids compare under COLLATE "C"."""
    ctx, cid = parse_cursor_str(cursor) if str_id else parse_cursor(cursor)
    r = await db.execute(text("select pg_snapshot_xmin(pg_current_snapshot())::text, pg_snapshot_xmax(pg_current_snapshot())::text"))
    wm, xm = (int(v) for v in r.one())
    if ctx >= xm:
        return {"invalid": True, "items": [], "next_cursor": cursor, "has_more": False}
    where_vis = visibility
    if allowed_branches:
        gone = literal_column(f"{table}.left_branches").op("&&")(
            cast(bindparam("allowed", list(allowed_branches), type_=ARRAY(String)), ARRAY(Text)))
        where_vis = or_(visibility, gone)
    stmt = (select(Model.id, literal_column(f"{table}.tx::text").label("tx"))
            .where(Model.company_code == company)
            .where(text(f"({table}.tx > CAST(CAST(:ctx AS text) AS xid8) OR ({table}.tx = CAST(CAST(:ctx AS text) AS xid8) AND {table}.id COLLATE \"C\" > CAST(:cid AS text)))" if (str_id and cid is not None) else f"{table}.tx > CAST(CAST(:ctx AS text) AS xid8)" if str_id else f"({table}.tx, {table}.id) > (CAST(CAST(:ctx AS text) AS xid8), :cid)").bindparams(**({"ctx": str(ctx)} if (str_id and cid is None) else {"ctx": str(ctx), "cid": cid})))
            .where(text(f"{table}.tx < CAST(CAST(:wm AS text) AS xid8)").bindparams(wm=str(wm)))
            .where(where_vis)
            .order_by(literal_column(f"{table}.tx"), literal_column(f'{table}.id COLLATE "C"') if str_id else Model.id).limit(limit + 1))
    rows = (await db.execute(stmt)).all()
    more = len(rows) > limit
    rows = rows[:limit]
    ids = [x.id for x in rows]
    docs, vis_ids = {}, set()
    if ids:
        for d in (await db.execute(select(Model).where(Model.id.in_(ids)))).scalars().all():
            docs[d.id] = d
        vis_ids = set((await db.execute(select(Model.id).where(Model.id.in_(ids)).where(visibility))).scalars().all())
    items = []
    for i in ids:
        d = docs.get(i)
        if d is None:
            continue
        items.append(serialize(d) if i in vis_ids else tomb(d))
    done = STR_DONE if str_id else MAX_ID
    nxt = f"{wm - 1}:{done}"
    if more:
        nxt = f"{int(rows[-1].tx)}:{('i' + rows[-1].id) if str_id else rows[-1].id}"
    return {"invalid": False, "items": items, "next_cursor": nxt, "has_more": more}

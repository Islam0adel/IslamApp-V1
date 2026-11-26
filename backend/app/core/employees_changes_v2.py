"""EXPERIMENT (isolated copy only): commit-safe change feed for employees. Needs migration 003.

Cursor "tx:id" (same watermark rule as transactions/coding). Rows are filtered per viewer with the
SAME visibility clause as /employees/changes, and the payload is shaped per viewer by the caller's
serializer. Viewer-scope changes (HR right, salary right, own-only, branches, viewable-employee list,
account identity) are in the scope fingerprint built by the route, so they invalidate the cursor.
A row that LEFT the viewer's branches, or whose account link (user_uid / user_email) moved away from
the viewer, comes back as an identifier-only removal (employees.left_branches
remembers every branch a row has left); a row that left because of a viewer-list or identity change
is covered by the fingerprint instead."""
from sqlalchemy import select, text, or_, bindparam, String, Text, cast, literal_column
from sqlalchemy.dialects.postgresql import ARRAY
from app.core.changes_v2 import parse_cursor, MAX_ID
from app.core.models import Employee

async def fetch(db, company, cursor, limit, visibility, allowed_branches, identities, serialize):
    ctx, cid = parse_cursor(cursor)
    r = await db.execute(text("select pg_snapshot_xmin(pg_current_snapshot())::text, pg_snapshot_xmax(pg_current_snapshot())::text"))
    wm, xm = (int(v) for v in r.one())
    if ctx >= xm:
        return {"invalid": True, "items": [], "next_cursor": cursor, "has_more": False}
    gone = None
    if allowed_branches:
        gone = literal_column("employees.left_branches").op("&&")(
            cast(bindparam("allowed", list(allowed_branches), type_=ARRAY(String)), ARRAY(Text)))
    if identities:
        link = literal_column("employees.left_links").op("&&")(
            cast(bindparam("ids", list(identities), type_=ARRAY(String)), ARRAY(Text)))
        gone = link if gone is None else or_(gone, link)
    stmt = (select(Employee.id, literal_column("employees.tx::text").label("tx"))
            .where(Employee.company_code == company)
            .where(text("(employees.tx, employees.id) > (CAST(CAST(:ctx AS text) AS xid8), :cid)").bindparams(ctx=str(ctx), cid=cid))
            .where(text("employees.tx < CAST(CAST(:wm AS text) AS xid8)").bindparams(wm=str(wm)))
            .where(or_(visibility, gone) if gone is not None else visibility)
            .order_by(literal_column("employees.tx"), Employee.id).limit(limit + 1))
    rows = (await db.execute(stmt)).all()
    more = len(rows) > limit
    rows = rows[:limit]
    ids = [x.id for x in rows]
    docs = {}
    if ids:
        for d in (await db.execute(select(Employee).where(Employee.id.in_(ids)))).scalars().all():
            docs[d.id] = d
    vis_ids = set()
    if ids:
        vis_ids = set((await db.execute(select(Employee.id).where(Employee.id.in_(ids)).where(visibility))).scalars().all())
    items = []
    for i in ids:
        d = docs.get(i)
        if d is None:
            continue
        if i in vis_ids:
            items.append(serialize(d))
        else:
            items.append({"id": d.id, "company_code": company, "code": d.code, "action": "delete", "tombstone": True,
                          "updated_at": d.updated_at.isoformat() if d.updated_at else None})
    nxt = f"{int(rows[-1].tx)}:{rows[-1].id}" if more else f"{wm - 1}:{MAX_ID}"
    return {"invalid": False, "items": items, "next_cursor": nxt, "has_more": more}

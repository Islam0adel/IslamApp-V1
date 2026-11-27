# backend/app/core/branch_catalog.py
"""Company-local catalog across both supported branch storage representations.

Reads only. Does not create branches, migrate records or assign account scope.
Coding is the normal editor, so its active name wins a duplicate legacy code.
"""
from sqlalchemy import select
from app.core.models import Branch, CodingRecord


# يجيب قائمة فروع الشركة (ممكن يقفل الصفوف للتعديل)
async def company_branch_catalog(session, company_code, *, lock=False):
    legacy = select(Branch.code, Branch.name).where(Branch.company_code == company_code).order_by(Branch.id)
    coded = select(CodingRecord.code, CodingRecord.name).where(
        CodingRecord.company_code == company_code,
        CodingRecord.category == 'branches',
        CodingRecord.is_deleted.is_(False)).order_by(CodingRecord.id)
    if lock:
        legacy = legacy.with_for_update()
        coded = coded.with_for_update()
    result = {}
    for query in (legacy, coded):
        for code, name in (await session.execute(query)).all():
            if isinstance(code, str) and code:
                result[code] = str(name or code)
    return result

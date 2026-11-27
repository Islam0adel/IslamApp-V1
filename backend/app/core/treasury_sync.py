# backend/app/core/treasury_sync.py
"""Scoped, transaction-serialized treasury changes. No device timestamps."""
import hashlib
import json
from sqlalchemy import select
from app.core.models import TreasurySyncState, TreasurySyncEntry, TreasuryTransferRecord


# يحوّل صف تحويل الخزينة لحمولة للتزامن
def record_payload(row):
    keys = ('id', 'company_code', 'branch_code', 'serial', 'from_treasury',
            'to_treasury', 'amount', 'statement', 'employee', 'date', 'is_deleted')
    result = {key: getattr(row, key) for key in keys}
    result['updated_at'] = row.updated_at.isoformat() if row.updated_at else None
    return result


# يخزّن إدخال تزامن جديد ويرفع رقم النسخة
async def store_entry(db, state, row):
    state.revision += 1
    entry = await db.get(TreasurySyncEntry, (row.company_code, row.id))
    if entry is None:
        entry = TreasurySyncEntry(company_code=row.company_code, transfer_id=row.id)
        db.add(entry)
    entry.revision = state.revision
    entry.payload = record_payload(row)
    await db.flush()
    return entry


# يقفل حالة تزامن الشركة حسب نوع قاعدة البيانات
async def lock_state(db, company):
    dialect = db.bind.dialect.name
    if dialect == 'postgresql':
        from sqlalchemy.dialects.postgresql import insert
    else:
        from sqlalchemy.dialects.sqlite import insert
    await db.execute(insert(TreasurySyncState).values(company_code=company,
        revision=0, initialized=False).on_conflict_do_nothing(index_elements=['company_code']))
    state = await db.scalar(select(TreasurySyncState).where(
        TreasurySyncState.company_code == company).with_for_update().execution_options(populate_existing=True))
    if not state.initialized:
        rows = (await db.scalars(select(TreasuryTransferRecord).where(
            TreasuryTransferRecord.company_code == company).order_by(TreasuryTransferRecord.id))).all()
        for row in rows:
            await store_entry(db, state, row)
        state.initialized = True
        await db.flush()
    return state


# يبني توكن نطاق التزامن من المستخدم والشركة والنمط والفروع
def scope_token(uid, company, mode, branches):
    value = json.dumps([uid, company, mode, sorted(branches or [])], separators=(',', ':'))
    return hashlib.sha256(value.encode()).hexdigest()

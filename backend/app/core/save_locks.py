# backend/app/core/save_locks.py
"""Transaction-scoped save locks, shared across PostgreSQL workers.

Locks protect record identity and existing per-branch serial allocation. They
expire with commit/rollback; no polling, lock table or background calls.
"""
import hashlib
import json
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


# يحوّل أجزاء المورد لمفتاح نصي ثابت للقفل
def _key(parts):
    encoded = json.dumps(parts, ensure_ascii=False, separators=(",", ":")).encode()
    return int.from_bytes(hashlib.sha256(encoded).digest()[:8], "big", signed=True)


# يقفل موارد الحفظ في المعاملة عشان العمليات المتزامنة تتسلسل
async def lock_save(db, *resources):
    # Non-persistent route doubles do not have a database transaction to lock.
    if not isinstance(db, AsyncSession):
        return
    dialect = db.get_bind().dialect.name
    if dialect == "postgresql":
        # Stable order also applies when one save touches multiple resources.
        for key in sorted({_key(resource) for resource in resources}):
            await db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": key})
    elif dialect == "sqlite" and not db.in_transaction():
        # Local regression fixtures use SQLite's own write transaction lock.
        await db.execute(text("BEGIN IMMEDIATE"))

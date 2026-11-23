"""Loopback-only journal client test server. Real routes/SQLite, fake identity.
No production app startup, external auth or database is invoked.
Run: DATABASE_URL=postgresql+asyncpg://u:p@127.0.0.1/unused python ...
"""
import asyncio
import os
import sys
import tempfile
from pathlib import Path
from contextlib import asynccontextmanager

os.environ.setdefault('DATABASE_URL', 'postgresql+asyncpg://u:p@127.0.0.1/unused')
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fastapi import FastAPI
from sqlalchemy import select, func, update, delete
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models
from app.core.database import get_db
from app.routes import transactions

folder = tempfile.TemporaryDirectory(prefix='journal_asgi_')
engine = create_async_engine('sqlite+aiosqlite:///' + folder.name + '/journal.db')
factory = async_sessionmaker(engine, expire_on_commit=False)
profile = {'uid': 'uid-A', 'role': 'employee', 'company_code': 'C1',
           'allowed_branches': ['B1', 'B2'], 'permissions': {
               'حركة الخزينة': {'ادخال اذون': True, 'التعديل': True, 'المعاينة': True}}}

async def db_override():
    async with factory() as db:
        yield db

@asynccontextmanager
async def lifespan(app):
    async with engine.begin() as conn:
        await conn.run_sync(models.Base.metadata.create_all)
    yield
    await engine.dispose()
    folder.cleanup()

app = FastAPI(lifespan=lifespan)
app.dependency_overrides[get_db] = db_override

@app.middleware('http')
async def fixture_identity(request, call_next):
    request.state.auth_user = profile
    return await call_next(request)

async def discard_broadcast(*args, **kwargs):
    pass
transactions.manager.broadcast = discard_broadcast
app.include_router(transactions.router, prefix='/transactions')

@app.post('/__fixture/reset')
async def reset():
    async with factory() as db:
        for table in reversed(models.Base.metadata.sorted_tables):
            await db.execute(delete(table))
        await db.commit()
    return {'ok': True}

@app.post('/__fixture/delete')
async def delete_journal():
    async with factory() as db:
        await db.execute(update(models.Transaction).values(is_deleted=True))
        await db.commit()
    return {'ok': True}

@app.get('/__fixture/state')
async def state():
    async with factory() as db:
        return {'rows': await db.scalar(select(func.count()).select_from(models.Transaction)),
                'receipts': await db.scalar(select(func.count()).select_from(models.JournalSaveReceipt)),
                'settlements': await db.scalar(select(func.count()).select_from(models.SupplierSettlementRecord))}

if __name__ == '__main__':
    import uvicorn
    uvicorn.run(app, host='127.0.0.1', port=int(os.environ.get('JOURNAL_TEST_PORT', '58731')), log_level='warning')

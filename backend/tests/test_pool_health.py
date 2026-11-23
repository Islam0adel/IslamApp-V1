import asyncio
import os
from types import SimpleNamespace

import asyncpg
import pytest
from sqlalchemy import exc, text
from sqlalchemy.ext.asyncio import create_async_engine

from app.core.pool_health import install_asyncpg_pool_health_check


def test_simple_query_ping_and_failure_boundaries():
    engine = create_async_engine('postgresql+asyncpg://unused', pool_pre_ping=False)
    install_asyncpg_pool_health_check(engine)
    class Driver:
        closed = False
        error = None
        calls = []
        async def execute(self, query):
            self.calls.append(query)
            if self.error: raise self.error
        def is_closed(self): return self.closed
    raw = Driver()
    class Adapter:
        driver_connection = raw
        def run_async(self, fn): return asyncio.run(fn(raw))
    adapter = Adapter()
    record = SimpleNamespace(info={})
    # Call only our last-added listeners, not dialect initialization.
    connected = list(engine.sync_engine.pool.dispatch.connect)[-1]
    checkout = list(engine.sync_engine.pool.dispatch.checkout)[-1]
    connected(adapter, record)
    checkout(adapter, record, None)
    assert raw.calls == []
    checkout(adapter, record, None)
    assert raw.calls == ['SELECT 1']
    raw.error = asyncpg.ConnectionDoesNotExistError('test disconnected')
    with pytest.raises(exc.InvalidatePoolError): checkout(adapter, record, None)
    raw.error = OSError('test transport')
    with pytest.raises(exc.InvalidatePoolError): checkout(adapter, record, None)
    raw.error = asyncpg.InterfaceError('test closed'); raw.closed = True
    with pytest.raises(exc.InvalidatePoolError): checkout(adapter, record, None)
    raw.closed = False
    with pytest.raises(asyncpg.InterfaceError): checkout(adapter, record, None)
    raw.error = asyncpg.InsufficientPrivilegeError('test access denied')
    with pytest.raises(asyncpg.InsufficientPrivilegeError): checkout(adapter, record, None)


def test_reject_wrong_driver_and_duplicate_pre_ping():
    wrong = create_async_engine('sqlite+aiosqlite://')
    with pytest.raises(ValueError): install_asyncpg_pool_health_check(wrong)
    duplicate = create_async_engine('postgresql+asyncpg://unused', pool_pre_ping=True)
    with pytest.raises(ValueError): install_asyncpg_pool_health_check(duplicate)


@pytest.mark.skipif(not os.getenv('TEST_POOL_HEALTH_DATABASE_URL'), reason='isolated local PostgreSQL required')
def test_real_postgres_transactions_and_dead_connection_recovery():
    async def work():
        url = os.environ['TEST_POOL_HEALTH_DATABASE_URL']
        engine = create_async_engine(url, pool_pre_ping=False, pool_size=1, max_overflow=0)
        install_asyncpg_pool_health_check(engine)
        observer = await asyncpg.connect(url.replace('postgresql+asyncpg:', 'postgresql:'))
        try:
            async with engine.begin() as c:
                await c.execute(text('create temporary table pool_health_test (value integer)'))
                await c.execute(text('insert into pool_health_test values (1)'))
            # Reused checkout, business transaction and rollback unchanged.
            async with engine.connect() as c:
                raw = await c.get_raw_connection()
                assert not raw.driver_connection.is_in_transaction()
                pid = (await c.execute(text('select pg_backend_pid()'))).scalar()
                await c.execute(text('insert into pool_health_test values (2)'))
            async with engine.connect() as c:
                assert (await c.execute(text('select count(*) from pool_health_test'))).scalar() == 1
            await observer.execute('select pg_terminate_backend($1)', pid)
            async with engine.connect() as c:
                assert (await c.execute(text('select 42'))).scalar() == 42
                new_pid = (await c.execute(text('select pg_backend_pid()'))).scalar()
                assert new_pid != pid
                raw = await c.get_raw_connection()
                driver = raw.driver_connection
            await driver.close()
            async with engine.connect() as c:
                assert (await c.execute(text('select 7'))).scalar() == 7
        finally:
            await observer.close()
            await engine.dispose()
    asyncio.run(work())

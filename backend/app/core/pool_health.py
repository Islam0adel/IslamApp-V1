# backend/app/core/pool_health.py
"""One-round-trip liveness check for asyncpg pooled connections.

Uses the driver's public simple-query execute API, not a prepared statement.
The SELECT 1 runs as one implicit, statement-local PostgreSQL transaction, so
it needs no explicit BEGIN/ROLLBACK or PgBouncer session affinity. Business
transactions and fresh authorization are unchanged.
"""
import asyncpg
from sqlalchemy import event, exc


# يركّب فحص صحة اتصالات pool الخاص بـasyncpg على الـengine
def install_asyncpg_pool_health_check(engine):
    if engine.dialect.name != 'postgresql' or engine.dialect.driver != 'asyncpg':
        raise ValueError('This pool health check requires postgresql+asyncpg')
    if engine.pool._pre_ping:
        raise ValueError('Do not install two checkout health checks')

    # يعلّم الاتصال الجديد إنه طازج
    @event.listens_for(engine.sync_engine, 'connect')
    def connected(dbapi_connection, connection_record):
        connection_record.info['_asyncpg_health_fresh'] = True

    # يفحص صحة الاتصال عند سحبه من الـpool (ping) ويستبدله لو ميت
    @event.listens_for(engine.sync_engine, 'checkout')
    def checkout(dbapi_connection, connection_record, connection_proxy):
        # Same fresh-connection skip as SQLAlchemy's built-in pre-ping.
        if connection_record.info.pop('_asyncpg_health_fresh', False):
            return
        try:
            dbapi_connection.run_async(lambda raw: raw.execute('SELECT 1'))
        except (asyncpg.PostgresConnectionError, OSError) as error:
            raise exc.InvalidatePoolError('Connection lost during pool health check') from error
        except (asyncpg.InterfaceError, asyncpg.PostgresError) as error:
            if dbapi_connection.driver_connection.is_closed():
                raise exc.InvalidatePoolError('Closed connection during pool health check') from error
            raise

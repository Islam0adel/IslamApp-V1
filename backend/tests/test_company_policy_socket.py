"""Actual WS handshake/explicit/mutation paths with synthetic identity and SQL.

No activation endpoint is used. Active rows are explicit test fixtures.
"""
import asyncio
import copy
from contextlib import asynccontextmanager

import pytest
from fastapi import WebSocketDisconnect
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.core import models
from app.core.company_policy_store import load_effective_policy_profile
from app.core.sync import ConnectionManager
from app.routes import sync as routes, auth
from test_notification_revocation import Database, Socket, EMAIL

UID = 'fixture-target'
RAW = {'uid': UID, 'email': EMAIL, 'role': 'admin', 'job_code': '201',
       'company_code': 'C1', 'is_active': True, 'status': 'active',
       'allowed_branches': ['B1'], 'permissions': {'المبيعات': {'حذف': True}}}
CONFIG = {'company_permissions': {'المبيعات': {'تعديل': True}}, 'admin_profiles': {
    UID: {'operating_permissions': {'المبيعات': {'تعديل': True}}, 'delegable_permissions': {}}
}}

class HandshakeSocket(Socket):
    def __init__(self): super().__init__(); self.accepted = 0
    async def accept(self): self.accepted += 1
    async def receive_json(self): return {'type': 'auth', 'token': 'fixture-token'}
    async def receive_text(self): raise WebSocketDisconnect()

class CapturingManager(ConnectionManager):
    def __init__(self): super().__init__(); self.registered = []
    async def connect(self, *args, **kwargs):
        await super().connect(*args, **kwargs)
        self.registered.append(copy.deepcopy(kwargs['profile']))

@asynccontextmanager
async def fixture(tmp_path, monkeypatch, *, active=True, role='admin', assigned=True):
    engine = create_async_engine('sqlite+aiosqlite:///' + str(tmp_path / 'socket-policy.db'))
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection: await connection.run_sync(models.Base.metadata.create_all)
    config = copy.deepcopy(CONFIG)
    if not assigned: config['admin_profiles'] = {}
    async with factory() as session:
        session.add(models.Company(code='C1', name='Fixture', is_active=True))
        if active: session.add(models.CompanyPermissionPolicy(company_code='C1', revision=1, active_revision=1, active=config))
        await session.commit()
    state = {**copy.deepcopy(RAW), 'role': role}
    database = Database(state); manager = CapturingManager()
    monkeypatch.setattr(routes, 'AsyncSessionLocal', factory)
    monkeypatch.setattr(auth, 'AsyncSessionLocal', factory)
    monkeypatch.setattr(routes, 'firebase_db', database)
    monkeypatch.setattr(auth, 'db', database)
    monkeypatch.setattr(routes, 'manager', manager)
    monkeypatch.setattr(auth, 'sync_manager', manager)
    monkeypatch.setattr(routes.admin_auth, 'verify_id_token', lambda *a, **kw: {'uid': UID, 'email': EMAIL})
    try: yield state, database, manager, factory, engine
    finally: await engine.dispose()

@pytest.mark.parametrize('role,assigned,edit', [('admin', True, True), ('admin', False, False), ('employee', True, False)])
def test_actual_handshake_uses_current_sql_policy(role, assigned, edit, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch, role=role, assigned=assigned) as (_, _, manager, _, _):
            socket = HandshakeSocket(); await routes.websocket_endpoint(socket, 'C1')
            assert socket.accepted == 1 and not socket.closed
            assert [m['type'] for m in socket.sent] == ['auth_success']
            profile = manager.registered[0]
            assert profile['company_policy_active'] is True and profile['company_policy_revision'] == 1
            assert profile['role'] == role and profile['allowed_branches'] == ['B1']
            assert profile['permissions'] == ({'المبيعات': {'إضافة': True, 'تعديل': True}} if edit else {})
    asyncio.run(run())

@pytest.mark.parametrize('role,accept', [('admin', False), ('super_admin', True)])
def test_policy_source_failure_cannot_register_a_legacy_admin_fallback(role, accept, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch, role=role) as (_, _, manager, _, engine):
            async with engine.begin() as connection:
                await connection.run_sync(models.CompanyPermissionPolicy.__table__.drop)
            socket = HandshakeSocket(); await routes.websocket_endpoint(socket, 'C1')
            assert bool(manager.registered) is accept
            assert socket.closed == ([] if accept else [1008])
            if accept: assert manager.registered[0]['company_policy_active'] is False
    asyncio.run(run())

@pytest.mark.parametrize('active', [False, True])
def test_handshake_never_poison_raw_source_or_infer_legacy_grants(active, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch, active=active) as (state, _, manager, _, _):
            original = copy.deepcopy(state)
            await routes.websocket_endpoint(HandshakeSocket(), 'C1')
            assert state == original
            profile = manager.registered[0]
            assert profile['company_policy_active'] is active
            if not active: assert profile['permissions'] == RAW['permissions']
    asyncio.run(run())

def test_explicit_refresh_sees_sql_only_revocation_without_raw_profile_change(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, manager, factory, _):
            async with factory() as session:
                initial = await load_effective_policy_profile(session, state, role='admin')
                row = await session.get(models.CompanyPermissionPolicy, 'C1')
                row.active = {'company_permissions': {}, 'admin_profiles': {}}; row.active_revision = 2
                await session.commit()
            socket = Socket(); await manager.connect('C1', socket, accept_connection=False, profile=initial)
            await routes.refresh_socket_profile(socket, 'C1', EMAIL, UID)
            current = manager.connection_profiles[socket]
            assert current['company_policy_revision'] == 2 and current['permissions'] == {}
            assert [m['type'] for m in socket.sent] == ['permissions_changed']
            assert state['permissions'] == RAW['permissions']
    asyncio.run(run())

def test_explicit_policy_failure_holds_then_recovers_only_from_verified_source(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, manager, factory, engine):
            socket = Socket(); await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(state))
            async with engine.begin() as connection: await connection.run_sync(models.CompanyPermissionPolicy.__table__.drop)
            await routes.refresh_socket_profile(socket, 'C1', EMAIL, UID)
            assert manager.connection_profiles[socket]['_permissions_invalidated'] is True
            async with engine.begin() as connection: await connection.run_sync(models.CompanyPermissionPolicy.__table__.create)
            async with factory() as session:
                session.add(models.CompanyPermissionPolicy(company_code='C1', revision=2, active_revision=2,
                    active={'company_permissions': {}, 'admin_profiles': {}}))
                await session.commit()
            await routes.refresh_socket_profile(socket, 'C1', EMAIL, UID)
            current = manager.connection_profiles[socket]
            assert current['_permissions_invalidated'] is False and current['permissions'] == {}
            assert [m['type'] for m in socket.sent] == ['permissions_changed', 'permissions_changed']
    asyncio.run(run())

def test_explicit_mutation_refresh_keeps_socket_policy_clipped(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, manager, factory, _):
            socket = Socket(); await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(state))
            await auth._notify_permissions_changed('C1', EMAIL)
            current = manager.connection_profiles[socket]
            assert current['_permissions_invalidated'] is False
            assert current['permissions'] == {'المبيعات': {'إضافة': True, 'تعديل': True}}
            async with factory() as session:
                row = await session.get(models.CompanyPermissionPolicy, 'C1')
                row.active = {'company_permissions': {}, 'admin_profiles': {}}; row.active_revision = 2
                await session.commit()
            await auth._notify_permissions_changed('C1', EMAIL)
            assert manager.connection_profiles[socket]['permissions'] == {}
            assert [m['type'] for m in socket.sent] == ['permissions_changed', 'user_directory_changed', 'permissions_changed', 'user_directory_changed']
            assert [m for m in socket.sent if m['type']=='user_directory_changed']==[{'type':'user_directory_changed','data':{'company_code':'C1'},'suppress_notification':True}]*2
    asyncio.run(run())


def test_idle_socket_has_no_profile_task_or_db_reads_between_messages(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, database, manager, factory, _):
            class IdleSocket(HandshakeSocket):
                async def receive_text(self):
                    # Advancing a virtual idle window cannot schedule any DB work:
                    # the endpoint is blocked on receive, not a minute timer.
                    assert not any('refresh_socket_profile' in repr(t.get_coro()) for t in asyncio.all_tasks())
                    raise WebSocketDisconnect()
            def forbidden(*args, **kwargs):
                raise AssertionError('Idle periodic profile validation was started')
            monkeypatch.setattr(routes, 'refresh_socket_profile', forbidden)
            await routes.websocket_endpoint(IdleSocket(), 'C1')
            assert manager.registered
    asyncio.run(run())


def test_company_toggle_holds_and_signals_all_local_sockets_after_commit(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from app.core import auth_middleware
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, manager, factory, _):
            socket = Socket()
            await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(state))
            auth_middleware._COMPANY_CACHE['C1'] = (999999999999, True)
            monkeypatch.setattr(auth, '_require_program_admin', lambda request: None)
            async with factory() as session:
                await auth.toggle_company_status(SimpleNamespace(), 'C1', False, '99', session)
            assert 'C1' not in auth_middleware._COMPANY_CACHE
            assert manager.connection_profiles[socket]['_permissions_invalidated'] is True
            assert [m['type'] for m in socket.sent] == ['permissions_changed']
            async with factory() as session:
                assert (await session.get(models.Company, 'C1')).is_active is False
    asyncio.run(run())


def test_identity_free_admin_hints_cross_company_only_to_root(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, manager, _, _):
            root, other, local = Socket(), Socket(), Socket()
            await manager.connect('C2', root, accept_connection=False, profile={**state, 'role':'super_admin'})
            await manager.connect('C2', other, accept_connection=False, profile={**state, 'role':'admin'})
            await manager.connect('C1', local, accept_connection=False, profile=copy.deepcopy(state))
            await manager.notify_user_directory_changed('C1')
            assert [m['type'] for m in root.sent] == ['user_directory_changed']
            assert other.sent == [] and len(local.sent) == 1
            await manager.notify_company_directory_changed()
            assert root.sent[-1] == {'type':'company_directory_changed','data':{},'suppress_notification':True}
            assert len(local.sent) == 1 and other.sent == []
    asyncio.run(run())


def test_idle_virtual_time_601_seconds_never_rechecks_firestore_or_sql(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, database, manager, _, _):
            loop = asyncio.get_running_loop()
            clock = [loop.time()]
            monkeypatch.setattr(loop, 'time', lambda: clock[0])
            entered = asyncio.Event()
            release = asyncio.Event()
            class Waiting(HandshakeSocket):
                async def receive_text(self):
                    entered.set()
                    await release.wait()
                    raise WebSocketDisconnect()
            socket = Waiting()
            task = asyncio.create_task(routes.websocket_endpoint(socket, 'C1'))
            await entered.wait()
            def no_reads(*args, **kwargs):
                raise AssertionError('Idle connection performed a database read')
            monkeypatch.setattr(database, 'collection', no_reads)
            monkeypatch.setattr(routes, 'AsyncSessionLocal', no_reads)
            # The real endpoint is waiting on a socket. Advance the event loop
            # clock through ten minute-boundaries, waking every due timer.
            for _ in range(11):
                clock[0] += 61
                await asyncio.sleep(0)
                await asyncio.sleep(0)
            assert not task.done()
            assert [m['type'] for m in socket.sent] == ['auth_success']
            release.set()
            await task
    asyncio.run(run())

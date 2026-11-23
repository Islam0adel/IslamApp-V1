"""Current policy at actual live dispatch, using real SQL and synthetic sockets.

No timer, activation endpoint, real identity or network delivery is used.
"""
import asyncio
import copy
from contextlib import asynccontextmanager

import pytest
from sqlalchemy import update, event as sql_event

from app.core import models, database as core_db, sync as live, notification_events as events
from app.core.company_policy_store import load_effective_policy_profile
from test_company_policy_push import fixture as push_fixture
from test_company_policy_socket import UID, EMAIL
from test_notification_revocation import Socket


def business(kind='transaction', **fields):
    return {'type': kind, 'suppress_notification': True,
        'data': {'company_code': 'C1', 'branch_code': 'B1', 'serial': 1,
                 'statement': 'Synthetic private row', **fields}}

def business_messages(socket): return [m for m in socket.sent if m.get('type') != 'permissions_changed']

@asynccontextmanager
async def fixture(tmp_path, monkeypatch):
    async with push_fixture(tmp_path, monkeypatch) as (state, source, factory, engine, _, _):
        monkeypatch.setattr(core_db, 'AsyncSessionLocal', factory)
        monkeypatch.setattr(live, 'firebase_db', source)
        manager = live.ConnectionManager()
        async with factory() as db:
            profile = await load_effective_policy_profile(db, state, role=state['role'])
        socket = Socket(); await manager.connect('C1', socket, accept_connection=False, profile=profile)
        yield state, source, factory, engine, manager, socket

@pytest.mark.parametrize('change', ['policy', 'blocked', 'uid', 'company', 'branches', 'role',
                                   'source', 'company-disabled', 'policy-source', 'policy-removed',
                                   'empty-branches', 'missing-branches', 'invalid-branches'])
def test_revocation_or_failed_verification_stops_actual_live_data_before_periodic_refresh(change, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, source, factory, engine, manager, socket):
            if change == 'blocked': state['is_active'] = False
            if change == 'uid': state['uid'] = 'different-owner'
            if change == 'company': state['company_code'] = 'C2'
            if change == 'branches': state['allowed_branches'] = ['B2']
            if change == 'empty-branches': state['allowed_branches'] = []
            if change == 'missing-branches': state.pop('allowed_branches')
            if change == 'invalid-branches': state['allowed_branches'] = ['all', 'B1']
            if change == 'role': state['role'] = 'employee'
            if change == 'source': source.doc.fail_read = True
            if change == 'policy-source':
                async with engine.begin() as connection:
                    await connection.run_sync(models.CompanyPermissionPolicy.__table__.drop)
            if change in ('policy', 'company-disabled', 'policy-removed'):
                async with factory() as db:
                    if change == 'company-disabled':
                        row = await db.get(models.Company, 'C1'); row.is_active = False
                    else:
                        row = await db.get(models.CompanyPermissionPolicy, 'C1')
                        row.active = None if change == 'policy-removed' else {'company_permissions': {}, 'admin_profiles': {}}
                        row.active_revision = None if change == 'policy-removed' else 2
                    await db.commit()
            await manager.broadcast('C1', business())
            assert not business_messages(socket)
            assert any(m['type'] == 'permissions_changed' for m in socket.sent)
    asyncio.run(run())


def test_active_multi_device_batch_uses_one_policy_and_one_account_read(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, source, _, engine, manager, socket):
            second = Socket()
            await manager.connect('C1', second, accept_connection=False,
                profile=copy.deepcopy(manager.connection_profiles[socket]))
            reads = []; queries = []; original = source.doc.get
            def counted_source(): reads.append(1); return original()
            def counted_sql(conn, cursor, statement, params, context, executemany):
                if statement.lstrip().upper().startswith('SELECT') and models.CompanyPermissionPolicy.__tablename__ in statement:
                    queries.append(statement)
            monkeypatch.setattr(source.doc, 'get', counted_source)
            sql_event.listen(engine.sync_engine, 'before_cursor_execute', counted_sql)
            await manager.broadcast('C1', business())
            assert len(business_messages(socket)) == len(business_messages(second)) == 1
            assert len(reads) == len(queries) == 1
    asyncio.run(run())


def test_live_data_does_not_stop_when_notifications_or_menu_are_hidden(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, factory, _, manager, socket):
            rights = {'حركة الخزينة': {'المعاينة': True},
                      'صلاحيات عامة': {'إظهار الإشعارات': False, 'إظهار حركة الخزينة': False}}
            async with factory() as db:
                row = await db.get(models.CompanyPermissionPolicy, 'C1')
                row.active = {'company_permissions': rights, 'admin_profiles': {
                    UID: {'operating_permissions': rights, 'delegable_permissions': {}}}}
                row.active_revision = 2; await db.commit()
            await manager.broadcast('C1', business())
            assert len(business_messages(socket)) == 1
            assert not events.recipient_allowed(manager.connection_profiles[socket], 'daily', 'B1')
    asyncio.run(run())


def test_add_only_live_lookup_is_minimal_and_does_not_grant_invoice_view(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, factory, _, manager, socket):
            rights = {'المبيعات': {'إضافة': True}}
            async with factory() as db:
                row = await db.get(models.CompanyPermissionPolicy, 'C1')
                row.active = {'company_permissions': rights, 'admin_profiles': {
                    UID: {'operating_permissions': rights, 'delegable_permissions': {}}}}
                row.active_revision = 2; await db.commit()
            await manager.broadcast('C1', business('sale'))
            assert not business_messages(socket)
            await manager.broadcast('C1', business('coding', category='items', code='I1', name='Synthetic item',
                wholesale_price=100, profit_margin=20, selling_price=150))
            messages = business_messages(socket)
            assert len(messages) == 1 and messages[0]['type'] == 'coding'
            assert messages[0]['data']['selling_price'] == 150
            assert 'wholesale_price' not in messages[0]['data'] and 'profit_margin' not in messages[0]['data']
            profile = manager.connection_profiles[socket]
            assert 'التكويد' not in profile['permissions'] and 'معاينة' not in profile['permissions']['المبيعات']
    asyncio.run(run())

@pytest.mark.parametrize('change', ['none', 'unlink', 'delete', 'filter'])
def test_live_own_hr_and_current_link_are_checked_without_an_invalidation_epoch(change, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, factory, _, manager, socket):
            state.update(allowed_branches=['B2'], hr_viewable_employees=['E2'])
            if change in ('unlink', 'delete'):
                async with factory() as db:
                    values = {'is_deleted': True} if change == 'delete' else {'user_uid': None, 'user_email': None}
                    await db.execute(update(models.Employee).values(**values)); await db.commit()
            payload = business('employee', code='E1', name='Synthetic self', user_uid=UID, user_email=EMAIL, salary=100)
            if change == 'filter':
                async with factory() as db:
                    row = await db.get(models.CompanyPermissionPolicy, 'C1')
                    rights = {'الموارد البشرية': {'canViewEmployees': True}}
                    row.active = {'company_permissions': rights, 'admin_profiles': {
                        UID: {'operating_permissions': rights, 'delegable_permissions': {}}}}
                    row.active_revision = 2; await db.commit()
            await manager.broadcast('C1', payload)
            messages = business_messages(socket)
            assert len(messages) == int(change == 'none')
            if messages: assert messages[0]['notification_scope'] == {'employee_code': 'E1', 'is_self': True}
    asyncio.run(run())


def test_local_epoch_change_during_policy_read_cannot_restore_older_projection(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, factory, _, manager, socket):
            calls = 0
            async def changing_loader(company, target=None):
                nonlocal calls
                result = await live.current_delivery_policy(company, target)
                calls += 1
                if calls == 1:
                    async with factory() as db:
                        row = await db.get(models.CompanyPermissionPolicy, 'C1')
                        row.active = {'company_permissions': {}, 'admin_profiles': {}}; row.active_revision = 2
                        await db.commit()
                    events.invalidate_company_recipients('C1')
                return result
            manager._policy_loader = changing_loader
            await manager.broadcast('C1', business())
            assert not business_messages(socket)
            assert manager.connection_profiles[socket]['permissions'] == {}
            assert calls >= 2
    asyncio.run(run())


def test_control_channel_cannot_send_unfiltered_business_data(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, _, _, manager, socket):
            await manager.send_to_user('C1', EMAIL, business('employee', salary=100))
            assert not socket.sent
    asyncio.run(run())


def test_global_platform_admin_keeps_access_to_a_paused_company(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, factory, _, manager, socket):
            state['role'] = 'super_admin'
            async with factory() as db:
                row = await db.get(models.Company, 'C1'); row.is_active = False; await db.commit()
                profile = await load_effective_policy_profile(db, state, role='super_admin')
            manager.connection_profiles[socket] = {**profile, '_permissions_revision': 0, '_permissions_invalidated': False}
            await manager.broadcast('C1', business())
            assert len(business_messages(socket)) == 1
    asyncio.run(run())


def test_slow_socket_does_not_queue_other_verified_devices_behind_it(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, _, _, manager, socket):
            entered = asyncio.Event(); release = asyncio.Event(); fast = asyncio.Event()
            class Slow(Socket):
                async def send_json(self, message):
                    if message['type'] != 'permissions_changed': entered.set(); await release.wait()
                    await super().send_json(message)
            class Fast(Socket):
                async def send_json(self, message):
                    await super().send_json(message)
                    if message['type'] != 'permissions_changed': fast.set()
            slow, quick = Slow(), Fast()
            profile = copy.deepcopy(manager.connection_profiles[socket])
            manager.disconnect('C1', socket)
            await manager.connect('C1', slow, accept_connection=False, profile=copy.deepcopy(profile))
            await manager.connect('C1', quick, accept_connection=False, profile=copy.deepcopy(profile))
            task = asyncio.create_task(manager.broadcast('C1', business()))
            await entered.wait()
            await asyncio.wait_for(fast.wait(), timeout=1)
            release.set(); await task
            assert len(business_messages(slow)) == len(business_messages(quick)) == 1
    asyncio.run(run())


@pytest.mark.parametrize('change', ['own-right', 'unlink'])
def test_own_copy_rechecks_after_other_socket_io(change, tmp_path, monkeypatch):
    from types import SimpleNamespace
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, source, factory, _, manager, owner):
            other_email = 'other-fixture@example.invalid'; other_uid = 'other-fixture'
            other_state = {**copy.deepcopy(state), 'uid': other_uid, 'email': other_email}
            class MultiSource:
                def collection(self, name): assert name == 'users'; return self
                def document(self, email):
                    value = {EMAIL: state, other_email: other_state}[email]
                    document = SimpleNamespace(exists=True)
                    document.get = lambda: document
                    document.to_dict = lambda: copy.deepcopy(value)
                    return document
            monkeypatch.setattr(live, 'firebase_db', MultiSource())
            async with factory() as db:
                row = await db.get(models.CompanyPermissionPolicy, 'C1'); config = copy.deepcopy(row.active)
                config['company_permissions']['الموارد البشرية']['canViewEmployees'] = True
                config['admin_profiles'][other_uid] = {'operating_permissions': {'الموارد البشرية': {'canViewEmployees': True}},
                    'delegable_permissions': {}}
                row.active = config; row.active_revision = 2; await db.commit()
                broad_profile = await load_effective_policy_profile(db, other_state, role='admin')
            entered = asyncio.Event(); release = asyncio.Event()
            class SlowBroad(Socket):
                async def send_json(self, message):
                    if message['type'] != 'permissions_changed': entered.set(); await release.wait()
                    await super().send_json(message)
            broad = SlowBroad(); await manager.connect('C1', broad, accept_connection=False, profile=broad_profile)
            task = asyncio.create_task(manager.broadcast('C1', business('employee', code='E1', name='Synthetic self',
                user_uid=UID, user_email=EMAIL, salary=100)))
            await entered.wait()
            async with factory() as db:
                if change == 'unlink':
                    await db.execute(update(models.Employee).values(user_uid=None, user_email=None))
                else:
                    row = await db.get(models.CompanyPermissionPolicy, 'C1'); config = copy.deepcopy(row.active)
                    config['admin_profiles'][UID]['operating_permissions']['الموارد البشرية']['canViewOwnHRData'] = False
                    row.active = config; row.active_revision = 3
                await db.commit()
            release.set(); await task
            assert not business_messages(owner)
            assert len(business_messages(broad)) == 1
    asyncio.run(run())

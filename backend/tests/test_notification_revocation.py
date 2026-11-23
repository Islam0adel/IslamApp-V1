from policy_fixtures import legacy_delivery_policy
"""Same-process revocation, actual handlers/manager and SQLite notification rows.

Firestore, identity and push transport are synthetic. No live account is used.
This does not establish cross-worker invalidation or retract an already sent push.
"""
import asyncio
import copy
import time
from contextlib import asynccontextmanager
from types import SimpleNamespace

import pytest
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker

from app.core import models, notification_events as events
from app.core.sync import ConnectionManager
from app.routes import auth, notifications, sync as sync_routes

REAL_NOTIFY = auth._notify_permissions_changed

EMAIL = 'fixture-target@example.invalid'
OLD = {
    'uid': 'fixture-target', 'email': EMAIL, 'role': 'employee',
    'company_code': 'C1', 'allowed_branches': ['B1'], 'status': 'active',
    'permissions': {'حركة الخزينة': {'المعاينة': True}},
}
ACTOR = {'uid': 'fixture-owner', 'email': 'fixture-owner@example.invalid',
         'role': 'super_admin', 'company_code': 'C1'}


async def committed_permission_change(state, permissions, branches):
    """Exercise delivery after a synthetic committed source mutation.

    Transactional HTTP authorization is covered by permission-editor tests.
    These tests own subsequent cache, socket and push behavior only.
    """
    state.update(permissions=copy.deepcopy(permissions), allowed_branches=list(branches))
    await auth._notify_permissions_changed(state['company_code'], EMAIL)
    return {'status': 'success'}


def request(profile):
    return SimpleNamespace(state=SimpleNamespace(auth_user=profile))


class Document:
    id = EMAIL
    exists = True

    def __init__(self, state):
        self.state = state
        self.reference = self
        self.fail_read = False

    def get(self):
        if self.fail_read:
            raise RuntimeError('synthetic source unavailable')
        return self

    def to_dict(self):
        return copy.deepcopy(self.state)

    def update(self, changes):
        self.state.update(changes)

    def delete(self):
        self.exists = False


class Database:
    def __init__(self, state):
        self.doc = Document(state)

    def collection(self, name):
        assert name == 'users'
        return self

    def document(self, email):
        assert email == EMAIL
        return self.doc

    def where(self, *args, **kwargs):
        return self

    def stream(self):
        if self.doc.fail_read:
            raise RuntimeError('synthetic source unavailable')
        return [self.doc] if self.doc.exists else []


class Socket:
    def __init__(self):
        self.sent = []
        self.closed = []

    async def send_json(self, value):
        self.sent.append(copy.deepcopy(value))

    async def close(self, code):
        self.closed.append(code)


def setup_source(monkeypatch):
    state = copy.deepcopy(OLD)
    database = Database(state)
    manager = ConnectionManager(policy_loader=legacy_delivery_policy)
    async def verified_legacy_policy(session, source, *, role):
        # These account-revocation unit fixtures explicitly model a company
        # before reviewed activation. Active-policy tests use actual SQL.
        from app.core.company_policy_store import effective_policy_profile
        return effective_policy_profile(source, None, None, role=role)
    monkeypatch.setattr(auth, 'load_effective_policy_profile', verified_legacy_policy)
    monkeypatch.setattr(sync_routes, 'load_effective_policy_profile', verified_legacy_policy)
    monkeypatch.setattr(auth, 'db', database)
    monkeypatch.setattr(auth, 'sync_manager', manager)
    monkeypatch.setattr(events, 'firebase_db', database)
    monkeypatch.setattr(events, '_RECIPIENT_CACHE', {})
    monkeypatch.setattr(events, '_RECIPIENT_EPOCH', {})
    monkeypatch.setattr(sync_routes, 'firebase_db', database)
    from app.core import sync as core_sync
    monkeypatch.setattr(core_sync, 'firebase_db', database)
    monkeypatch.setattr(sync_routes, 'manager', manager)
    monkeypatch.setattr(auth, 'invalidate_profile_cache', lambda email: None)
    return state, database, manager


@asynccontextmanager
async def notification_db(tmp_path, monkeypatch, session_class=AsyncSession):
    engine = create_async_engine('sqlite+aiosqlite:///' + str(tmp_path / 'notifications.db'))
    factory = async_sessionmaker(engine, class_=session_class, expire_on_commit=False)
    monkeypatch.setattr(events, 'AsyncSessionLocal', factory)
    async with engine.begin() as connection:
        await connection.run_sync(models.Base.metadata.create_all)
    try:
        yield factory
    finally:
        await engine.dispose()


def business(branch='B1'):
    return {'type': 'transaction', 'action': 'add', 'suppress_notification': True,
            'data': {'company_code': 'C1', 'branch_code': branch, 'serial': 1,
                     'statement': 'Synthetic private detail'}}


@pytest.mark.parametrize('change', ['section', 'branch'])
def test_committed_permission_change_replaces_socket_and_recipient_snapshots(change, tmp_path, monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    pushes = []
    monkeypatch.setattr(events, 'send_push_to_user_bg', lambda **values: pushes.append(values))

    async def run():
        socket = Socket()
        await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(OLD))
        events._RECIPIENT_CACHE['C1'] = (time.monotonic(), [copy.deepcopy(OLD)])
        other = Socket()
        await manager.connect('C1', other, accept_connection=False,
                              profile={**copy.deepcopy(OLD), 'uid': 'other', 'email': 'other@example.invalid'})
        permissions = {'حركة الخزينة': {'المعاينة': change != 'section'}}
        branches = ['B2'] if change == 'branch' else ['B1']
        result = await committed_permission_change(state, permissions, branches)
        assert result['status'] == 'success'
        assert [m['type'] for m in socket.sent] == ['permissions_changed']
        assert not other.sent
        async with notification_db(tmp_path, monkeypatch) as factory:
            await manager.broadcast('C1', business())
            await events.prepare_and_persist_event('C1', business())
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification)) == 0
        assert [m['type'] for m in socket.sent] == ['permissions_changed']
        assert len(other.sent) == 1
        assert not pushes
        if change == 'branch':
            await manager.broadcast('C1', business('B2'))
            assert socket.sent[-1]['type'] == 'transaction'
    asyncio.run(run())


def test_failed_source_refresh_holds_business_and_own_copy_but_keeps_control(monkeypatch):
    state, database, manager = setup_source(monkeypatch)

    async def run():
        socket = Socket()
        await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(OLD))
        database.doc.fail_read = True
        await auth._notify_permissions_changed('C1', EMAIL)
        assert manager.connection_profiles[socket]['_permissions_invalidated'] is True
        await manager.broadcast('C1', business())
        await manager.send_to_user('C1', EMAIL, {'type': 'employee', 'data': {'user_email': EMAIL}})
        assert [m['type'] for m in socket.sent] == ['permissions_changed']
    asyncio.run(run())


@pytest.mark.parametrize('change', ['suspended', 'pending', 'inactive', 'different-uid', 'different-company'])
def test_unusable_fresh_profile_cannot_keep_old_business_access(change, monkeypatch):
    state, database, manager = setup_source(monkeypatch)

    async def run():
        socket = Socket()
        await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(OLD))
        if change in ('pending', 'suspended'):
            state['status'] = change
        elif change == 'inactive':
            state['is_active'] = False
        elif change == 'different-uid':
            state['uid'] = 'replacement-uid'
        else:
            state['company_code'] = 'C2'
        await auth._notify_permissions_changed('C1', EMAIL)
        await manager.broadcast('C1', business())
        assert [m['type'] for m in socket.sent] == ['permissions_changed']
    asyncio.run(run())


def test_actual_delete_notifies_after_source_is_deleted_and_blocks_existing_socket(tmp_path, monkeypatch):
    from test_permission_editor_integration import fixture, ACTOR as OWNER, TARGET
    from test_account_lifecycle import lifecycle_source
    from test_management_directory import grant
    async def run():
        async with fixture(tmp_path, monkeypatch) as (client, source, factory, notices):
            lifecycle_source(source, monkeypatch)
            await grant(factory, ['delete'])
            manager = ConnectionManager(policy_loader=legacy_delivery_policy)
            monkeypatch.setattr(auth, 'sync_manager', manager)
            # Test the real notify implementation, not fixture's collector.
            monkeypatch.setattr(auth, '_notify_permissions_changed', REAL_NOTIFY)
            monkeypatch.setattr(auth, 'AsyncSessionLocal', factory)
            socket = Socket()
            await manager.connect('C1', socket, accept_connection=False,
                profile={**copy.deepcopy(source.records[TARGET]), 'email': TARGET})
            response = await client.delete('/auth/admin/delete-user', params={'email': TARGET})
            assert response.status_code == 200, response.text
            assert TARGET not in source.records
            assert manager.connection_profiles[socket]['_permissions_invalidated'] is True
            await manager.broadcast('C1', business())
            assert socket.sent and all(value['type'] == 'permissions_changed' for value in socket.sent)
    asyncio.run(run())


@pytest.mark.parametrize('status', ['suspended', 'pending', 'inactive', 'different-company'])
def test_recipient_source_omits_disabled_accounts(status, monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    if status == 'inactive':
        state['is_active'] = False
    elif status == 'different-company':
        state['company_code'] = 'C2'
    else:
        state['status'] = status
    assert events._company_recipients('C1') == []


def test_explicit_read_cannot_restore_older_rights_over_an_explicit_mutation(monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    async def mutate_while_company_check_awaited(_):
        await committed_permission_change(state, {'حركة الخزينة': {'المعاينة': False}}, ['B1'])
        return True

    monkeypatch.setattr(sync_routes, '_company_active', mutate_while_company_check_awaited)

    async def run():
        socket = Socket()
        await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(OLD))
        await sync_routes.refresh_socket_profile(socket, 'C1', EMAIL, OLD['uid'])
        assert manager.connection_profiles[socket]['permissions']['حركة الخزينة']['المعاينة'] is False
        assert [m['type'] for m in socket.sent] == ['permissions_changed']
        await manager.broadcast('C1', business())
        assert len(socket.sent) == 1
    asyncio.run(run())


def test_explicit_refresh_releases_failed_read_hold_even_when_rights_are_unchanged(monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    async def active(_):
        return True

    monkeypatch.setattr(sync_routes, '_company_active', active)

    async def run():
        socket = Socket()
        await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(OLD))
        manager.replace_user_profile('C1', EMAIL, None)
        await sync_routes.refresh_socket_profile(socket, 'C1', EMAIL, OLD['uid'])
        assert manager.connection_profiles[socket]['_permissions_invalidated'] is False
        await manager.broadcast('C1', business())
        assert socket.sent[-1]['type'] == 'transaction'
    asyncio.run(run())


def test_healthy_allowed_event_still_persists_and_queues_exactly_one_push(tmp_path, monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    pushes = []
    monkeypatch.setattr(events, 'send_push_to_user_bg', lambda **values: pushes.append(values))

    async def run():
        async with notification_db(tmp_path, monkeypatch) as factory:
            await events.prepare_and_persist_event('C1', business())
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification)) == 1
                result = await notifications.list_notifications(
                    request(copy.deepcopy(state)), limit=100, after_id=None, unread_only=False, db=db)
                assert len(result['items']) == 1
            assert len(pushes) == 1 and pushes[0]['user_uid'] == OLD['uid']
    asyncio.run(run())


def test_invalidation_is_company_scoped(monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    preserved = (time.monotonic(), [{'uid': 'other'}])
    events._RECIPIENT_CACHE.update({'C1': (time.monotonic(), [OLD]), 'C2': preserved})
    events.invalidate_company_recipients('C1')
    assert 'C1' not in events._RECIPIENT_CACHE
    assert events._RECIPIENT_CACHE['C2'] is preserved
    assert events._RECIPIENT_EPOCH == {'C1': 1}


def test_push_recheck_source_failure_does_not_fall_back_to_old_recipient(tmp_path, monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    pushes = []
    monkeypatch.setattr(events, 'send_push_to_user_bg', lambda **values: pushes.append(values))
    fired = False

    class UnavailableDuringCommit(AsyncSession):
        async def commit(self):
            nonlocal fired
            if not fired:
                fired = True
                database.doc.fail_read = True
                await auth._notify_permissions_changed('C1', EMAIL)
            await super().commit()

    async def run():
        async with notification_db(tmp_path, monkeypatch, UnavailableDuringCommit):
            await events.prepare_and_persist_event('C1', business())
            assert fired and not pushes
    asyncio.run(run())


def test_explicit_read_rejects_a_profile_that_changed_company(monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    state['company_code'] = 'C2'

    async def run():
        socket = Socket()
        await manager.connect('C1', socket, accept_connection=False, profile=copy.deepcopy(OLD))
        await sync_routes.refresh_socket_profile(socket, 'C1', EMAIL, OLD['uid'])
        assert socket.closed == [1008]
    asyncio.run(run())


def test_push_is_rechecked_if_revocation_happens_during_notification_commit(tmp_path, monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    pushes = []
    monkeypatch.setattr(events, 'send_push_to_user_bg', lambda **values: pushes.append(values))
    fired = False

    class RevokeDuringCommit(AsyncSession):
        async def commit(self):
            nonlocal fired
            if not fired:
                fired = True
                await committed_permission_change(state, {'حركة الخزينة': {'المعاينة': False}}, ['B1'])
            await super().commit()

    async def run():
        async with notification_db(tmp_path, monkeypatch, RevokeDuringCommit) as factory:
            await events.prepare_and_persist_event('C1', business())
            assert fired and not pushes
            # This row was selected before revocation. It is historical server
            # storage, not an allowed delivery, and must stay hidden on reads.
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification)) == 1
                result = await notifications.list_notifications(
                    request(copy.deepcopy(state)), limit=100, after_id=None, unread_only=False, db=db)
                assert result['items'] == []
    asyncio.run(run())

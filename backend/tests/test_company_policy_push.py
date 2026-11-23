"""Policy-aware notification persistence and actual queued FCM execution.

SQLite, synthetic Firestore/identity/tokens/vendor transport. No real delivery.
"""
import asyncio
import copy
import time
from contextlib import asynccontextmanager

import pytest
from sqlalchemy import select, func, update

from app.core import models, notification_events as events, fcm_service as fcm
from app.routes import auth
from test_company_policy_socket import fixture as socket_fixture, UID, EMAIL

RIGHTS = {'صلاحيات عامة': {'إظهار الإشعارات': True, 'إظهار الموارد البشرية': True},
          'حركة الخزينة': {'المعاينة': True}, 'الموارد البشرية': {'canViewOwnHRData': True}}
TOKEN = 'synthetic-token-not-a-live-credential'

def event(hr=False):
    return {'type': 'hr_attendance' if hr else 'transaction', 'action': 'add',
            'data': {'company_code': 'C1', 'branch_code': 'B1', 'employee_code': 'E1',
                     'serial': 1, 'statement': 'Synthetic private notice'}}

@asynccontextmanager
async def fixture(tmp_path, monkeypatch, *, own=False):
    async with socket_fixture(tmp_path, monkeypatch) as (state, source, _, factory, engine):
        monkeypatch.setattr(events, 'AsyncSessionLocal', factory)
        monkeypatch.setattr(fcm, 'AsyncSessionLocal', factory)
        monkeypatch.setattr(events, 'firebase_db', source)
        monkeypatch.setattr(events, '_RECIPIENT_CACHE', {})
        monkeypatch.setattr(events, '_RECIPIENT_EPOCH', {})
        monkeypatch.setattr(fcm, 'is_fcm_enabled', lambda: True)
        sent = []; queued = []
        monkeypatch.setattr(fcm, '_send_sync', lambda *args: sent.append(args) or fcm.FcmSendResult(success_count=len(args[0])))
        monkeypatch.setattr(events, 'send_push_to_user_bg', lambda **target: queued.append(target))
        if own: state.update(allowed_branches=['B2'], hr_viewable_employees=['E2'])
        async with factory() as db:
            row = await db.get(models.CompanyPermissionPolicy, 'C1')
            row.active = {'company_permissions': copy.deepcopy(RIGHTS), 'admin_profiles': {
                UID: {'operating_permissions': copy.deepcopy(RIGHTS), 'delegable_permissions': {}}}}
            db.add(models.UserFcmToken(user_uid=UID, company_code='C1', fcm_token=TOKEN))
            db.add(models.Employee(company_code='C1', code='E1', name='Synthetic self', branch_code='B1',
                user_uid=UID, user_email=EMAIL))
            await db.commit()
        yield state, source, factory, engine, queued, sent

async def revoke(factory):
    async with factory() as db:
        row = await db.get(models.CompanyPermissionPolicy, 'C1')
        row.active = {'company_permissions': {}, 'admin_profiles': {}}; row.active_revision = 2
        await db.commit()

def test_persistence_projects_policy_and_bypasses_raw_recipient_ttl(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, factory, _, queued, _):
            original = copy.deepcopy(state)
            events._RECIPIENT_CACHE['C1'] = (time.monotonic(), [{**state, 'uid': 'stale-other-user'}])
            await events.prepare_and_persist_event('C1', event())
            assert len(queued) == 1 and queued[0]['user_uid'] == UID
            assert callable(queued[0]['authorization_check'])
            async with factory() as db:
                rows = (await db.scalars(select(models.Notification))).all()
                assert len(rows) == 1 and rows[0].recipient_uid == UID
            await revoke(factory)
            await events.prepare_and_persist_event('C1', event())
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification)) == 1
                assert await db.scalar(select(func.count()).select_from(models.AuditLog)) == 2
            assert len(queued) == 1 and state == original
            assert events._RECIPIENT_CACHE['C1'][1][0]['permissions'] == original['permissions']
    asyncio.run(run())

@pytest.mark.parametrize('change', ['none', 'policy', 'blocked', 'uid', 'company', 'branches',
                                   'preference', 'source', 'company-disabled', 'token-owner', 'policy-source', 'policy-removed',
                                   'empty-branches', 'missing-branches', 'invalid-branches'])
def test_actual_queued_send_rechecks_after_token_lookup(change, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, source, factory, engine, queued, sent):
            await events.prepare_and_persist_event('C1', event())
            assert len(queued) == 1
            entered = asyncio.Event(); release = asyncio.Event(); original = fcm.get_user_tokens
            async def gated_tokens(*args):
                value = await original(*args); entered.set(); await release.wait(); return value
            monkeypatch.setattr(fcm, 'get_user_tokens', gated_tokens)
            task = fcm.send_push_to_user_bg(**queued[0])
            assert task is not None
            await entered.wait()
            if change == 'policy': await revoke(factory)
            if change == 'policy-removed':
                async with factory() as db:
                    row = await db.get(models.CompanyPermissionPolicy, 'C1'); row.active = None; row.active_revision = None
                    await db.commit()
            if change == 'blocked': state['is_active'] = False
            if change == 'uid': state['uid'] = 'different-user'
            if change == 'company': state['company_code'] = 'C2'
            if change == 'branches': state['allowed_branches'] = ['B2']
            if change == 'empty-branches': state['allowed_branches'] = []
            if change == 'missing-branches': state.pop('allowed_branches')
            if change == 'invalid-branches': state['allowed_branches'] = ['all', 'B1']
            if change == 'source': source.doc.fail_read = True
            if change == 'policy-source':
                async with engine.begin() as connection:
                    await connection.run_sync(models.CompanyPermissionPolicy.__table__.drop)
            if change in ('preference', 'company-disabled', 'token-owner'):
                async with factory() as db:
                    if change == 'preference':
                        db.add(models.NotificationPreference(company_code='C1', user_uid=UID, user_email=EMAIL, sections={'daily': False}))
                    if change == 'company-disabled':
                        row = await db.get(models.Company, 'C1'); row.is_active = False
                    if change == 'token-owner':
                        await db.execute(update(models.UserFcmToken).values(user_uid='different-user'))
                    await db.commit()
            release.set(); await task
            assert len(sent) == (1 if change == 'none' else 0)
            if sent: assert sent[0][0] == [TOKEN]
    asyncio.run(run())

@pytest.mark.parametrize('change', ['none', 'unlink', 'delete', 'own-right'])
def test_queued_own_hr_survives_branch_list_exclusion_but_not_link_or_right_revocation(change, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch, own=True) as (_, _, factory, _, queued, sent):
            await events.prepare_and_persist_event('C1', event(hr=True))
            assert len(queued) == 1
            if change in ('unlink', 'delete'):
                async with factory() as db:
                    values = {'is_deleted': True} if change == 'delete' else {'user_uid': None, 'user_email': None}
                    await db.execute(update(models.Employee).values(**values)); await db.commit()
            if change == 'own-right': await revoke(factory)
            task = fcm.send_push_to_user_bg(**queued[0]); assert task is not None; await task
            assert len(sent) == int(change == 'none')
    asyncio.run(run())

def test_missing_execution_guard_never_sends(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, _, _, _, sent):
            await fcm.send_push_to_user(UID, 'C1', 'Synthetic', 'Not authorized')
            assert not sent
    asyncio.run(run())

def test_document_identifier_not_a_claimed_email_selects_recipient_role(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, factory, _, queued, _):
            monkeypatch.setattr(events, 'SUPER_ADMIN_EMAILS', {'claimed-root@example.invalid'})
            state['email'] = 'claimed-root@example.invalid'
            await revoke(factory)
            await events.prepare_and_persist_event('C1', event())
            assert not queued
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification)) == 0
    asyncio.run(run())


@pytest.mark.parametrize('change', ['none', 'uid', 'blocked', 'company', 'root-scope'])
def test_registration_push_also_carries_an_execution_guard(change, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, _, _, _, queued, sent):
            monkeypatch.setattr(auth, 'SUPER_ADMIN_EMAILS', {EMAIL})
            monkeypatch.setattr(events, 'SUPER_ADMIN_EMAILS', {EMAIL})
            monkeypatch.setattr(auth, 'send_push_to_user_bg', lambda **target: queued.append(target))
            await auth.notify_super_admins_of_registration_request('synthetic-request', {'name': 'Synthetic applicant'})
            assert len(queued) == 1 and callable(queued[0]['authorization_check'])
            if change == 'uid': state['uid'] = 'another-owner'
            if change == 'blocked': state['is_active'] = False
            if change == 'company': state['company_code'] = 'C2'
            if change == 'root-scope': monkeypatch.setattr(events, 'SUPER_ADMIN_EMAILS', set())
            task = fcm.send_push_to_user_bg(**queued[0]); assert task is not None; await task
            assert len(sent) == int(change == 'none')
    asyncio.run(run())

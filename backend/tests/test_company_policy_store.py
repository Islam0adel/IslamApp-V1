"""Persistent draft-only plumbing. Activation and runtime wiring remain gated."""
import asyncio
from copy import deepcopy
from datetime import datetime

import pytest
from fastapi import HTTPException
from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.core import models
from app.core.company_policy_store import (
    PolicyConflict, UnknownPolicyCompany, policy_profile, read_policy,
    save_policy_draft, validate_configuration,
)
from app.routes import auth


def config():
    return {
        'company_permissions': {'المبيعات': {'تعديل': True}},
        'admin_profiles': {'uid-admin': {
            'operating_permissions': {'المبيعات': {'إضافة': True}},
            'delegable_permissions': {'المبيعات': {'تعديل': True}},
        }},
    }


@pytest.mark.parametrize('case', ['shape', 'extra', 'admins-list', 'empty-uid', 'padded-uid',
                                  'missing-operating', 'extra-profile', 'truthy', 'above-ceiling'])
def test_invalid_draft_is_rejected(case):
    value = config()
    if case == 'shape': value = []
    if case == 'extra': value['activate'] = True
    if case == 'admins-list': value['admin_profiles'] = []
    if case in ('empty-uid', 'padded-uid'):
        value['admin_profiles']['' if case == 'empty-uid' else ' uid-admin'] = value['admin_profiles'].pop('uid-admin')
    if case == 'missing-operating': del value['admin_profiles']['uid-admin']['operating_permissions']
    if case == 'extra-profile': value['admin_profiles']['uid-admin']['role'] = 'super_admin'
    if case == 'truthy': value['company_permissions']['المبيعات']['تعديل'] = 1
    if case == 'above-ceiling': value['admin_profiles']['uid-admin']['delegable_permissions'] = {'المبيعات': {'حذف': True}}
    with pytest.raises(ValueError): validate_configuration(value)


@pytest.mark.parametrize('role,uid,permissions,expected,delegation', [
    ('admin', 'uid-admin', {}, {'المبيعات': {'إضافة': True}}, {'المبيعات': {'إضافة': True, 'تعديل': True}}),
    ('admin', 'different-uid', {'المبيعات': {'تعديل': True}}, {}, {}),
    ('employee', 'uid-admin', {'المبيعات': {'تعديل': True, 'حذف': True}}, {'المبيعات': {'إضافة': True, 'تعديل': True}}, {}),
    ('employee', 'employee', {}, {}, {}),
])
def test_projector_separates_ceiling_operating_and_delegation(role, uid, permissions, expected, delegation):
    original = {'uid': uid, 'permissions': permissions, 'allowed_branches': ['B2'], 'branch_code': 'B1'}
    before = deepcopy(original)
    result = policy_profile(original, config(), role=role)
    assert result['permissions'] == expected
    assert result['delegable_permissions'] == delegation
    assert result['company_policy_active'] is True
    assert result['allowed_branches'] == ['B2'] and result['branch_code'] == 'B1'
    assert original == before


def test_legacy_admin_is_not_assigned_new_grants_and_superadmin_remains_separate():
    profile = {'uid': 'uid-admin', 'permissions': {}, 'role': 'admin'}
    result = policy_profile(profile, None, role='admin')
    assert result['permissions'] == {} and result['company_policy_active'] is False
    root = policy_profile({'permissions': {'other': {'x': True}}}, config(), role='super_admin')
    assert root['permissions'] == {'other': {'x': True}}


def test_delegation_without_operating_never_becomes_an_operating_grant():
    value = config()
    value['admin_profiles']['uid-admin']['operating_permissions'] = {}
    assert policy_profile({'uid': 'uid-admin', 'allowed_branches': ['B1']}, value, role='admin')['permissions'] == {}


@pytest.mark.parametrize('revision', [True, '0', 1.0])
def test_draft_revision_is_not_coerced(revision):
    with pytest.raises(ValidationError):
        auth.CompanyPolicyDraftModel(expected_revision=revision, configuration=config())


@pytest.mark.parametrize('role', ['employee', 'admin'])
def test_only_program_admin_can_read_or_save_drafts(role, make_request):
    async def work():
        request = make_request({'role': role, 'uid': 'u', 'company_code': 'C1'})
        with pytest.raises(HTTPException) as read:
            await auth.get_company_permission_policy('C1', request, None)
        assert read.value.status_code == 403
        data = auth.CompanyPolicyDraftModel(expected_revision=0, configuration=config())
        with pytest.raises(HTTPException) as write:
            await auth.put_company_permission_policy_draft('C1', data, request, None)
        assert write.value.status_code == 403
    asyncio.run(work())


def test_real_store_roundtrip_cas_and_draft_never_activates(tmp_path, make_request,monkeypatch):
    async def work():
        engine = create_async_engine('sqlite+aiosqlite:///' + str(tmp_path / 'policy.db'))
        factory = async_sessionmaker(engine, expire_on_commit=False)
        async with engine.begin() as conn:
            await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as session:
                session.add_all([models.Company(code='C1', name='One'), models.Company(code='C2', name='Two')])
                await session.commit()
                initial = await read_policy(session, 'C1')
                assert initial['revision'] == 0 and initial['draft'] is None
                assert initial['status'] == 'legacy_review_required' and initial['active'] is None
                assert await session.scalar(select(models.CompanyPermissionPolicy)) is None
                from test_permission_editor_integration import Source, ACTOR
                from test_management_directory import install
                source=Source(root=True);install(source);monkeypatch.setattr(auth,'db',source)
                request = make_request(source.cached_actor)
                first = await auth.put_company_permission_policy_draft('C1', auth.CompanyPolicyDraftModel(
                    expected_revision=0, configuration=config()), request, session)
                assert first['revision'] == 1 and first['saved_as_draft'] is True
                assert first['authorization_changed'] is False and first['active'] is None
                for stale_revision in (0, 2):
                    with pytest.raises(PolicyConflict):
                        await save_policy_draft(session, 'C1', config(), expected_revision=stale_revision)
                second = await save_policy_draft(session, 'C1', config(), expected_revision=1)
                assert second['revision'] == 2
                assert second['active_revision'] is None and second['reviewed_by_uid'] is None
                other = await read_policy(session, 'C2')
                assert other['revision'] == 0 and other['draft'] is None
                with pytest.raises(UnknownPolicyCompany): await read_policy(session, 'missing')
                with pytest.raises(UnknownPolicyCompany):
                    await save_policy_draft(session, 'missing', config(), expected_revision=0)
                with pytest.raises(ValueError):
                    await save_policy_draft(session, 'C1', config(), expected_revision=-1)
                # Synthetic existing active state, not an activation endpoint.
                active = {'company_permissions': {}, 'admin_profiles': {}}
                row = await session.get(models.CompanyPermissionPolicy, 'C1')
                row.active = active
                row.active_revision = 1
                row.reviewed_by_uid = 'fixture-reviewer'
                row.reviewed_at = datetime(2026, 11, 22, 12, 0)
                await session.commit()
                with pytest.raises(PolicyConflict):
                    await save_policy_draft(session, 'C1', config(), expected_revision=2)
                third = await save_policy_draft(session, 'C1', config(), expected_revision=2, reconciled_active_revision=1)
                assert third['revision'] == 3 and third['active'] == active
                assert third['active_revision'] == 1 and third['reviewed_by_uid'] == 'fixture-reviewer'
                assert third['reviewed_at'] == '2026-11-22T12:00:00'
                assert third['status'] == 'active'
                with pytest.raises(HTTPException) as stale:
                    await auth.put_company_permission_policy_draft('C1', auth.CompanyPolicyDraftModel(
                        expected_revision=2, configuration=config()), request, session)
                assert stale.value.status_code == 409
                with pytest.raises(HTTPException) as unknown:
                    await auth.get_company_permission_policy('missing', request, session)
                assert unknown.value.status_code == 404
                bad = config(); bad['admin_profiles'] = []
                with pytest.raises(HTTPException) as invalid:
                    await auth.put_company_permission_policy_draft('C1', auth.CompanyPolicyDraftModel(
                        expected_revision=3, configuration=bad), request, session)
                assert invalid.value.status_code == 400
        finally:
            await engine.dispose()
    asyncio.run(work())


def test_activation_endpoint_requires_explicit_review_contract():
    paths = [route.path for route in auth.router.routes]
    assert '/companies/{company_code}/permission-policy/activate' in paths
    with pytest.raises(ValidationError):auth.CompanyPolicyActivationModel(expected_revision=1,source_review_token='token')


def test_real_concurrent_drafts_have_one_winner_for_insert_and_update(tmp_path):
    async def work():
        engine = create_async_engine('sqlite+aiosqlite:///' + str(tmp_path / 'race.db'))
        factory = async_sessionmaker(engine, expire_on_commit=False)
        async with engine.begin() as conn:
            await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as session:
                session.add(models.Company(code='C1', name='One'))
                await session.commit()
            for expected in (0, 1):
                barrier = asyncio.Event()
                entered = 0
                async def writer(variant):
                    nonlocal entered
                    async with factory() as session:
                        original = await read_policy(session, 'C1')
                        assert original['revision'] == expected
                        entered += 1
                        if entered == 2: barrier.set()
                        await barrier.wait()
                        value = config()
                        if variant:
                            value['admin_profiles']['uid-admin']['operating_permissions'] = {}
                        return await save_policy_draft(session, 'C1', value, expected_revision=expected)
                results = await asyncio.gather(writer(0), writer(1), return_exceptions=True)
                assert sum(isinstance(item, PolicyConflict) for item in results) == 1, results
                winners = [item for item in results if isinstance(item, dict)]
                assert len(winners) == 1 and winners[0]['revision'] == expected + 1
                async with factory() as session:
                    stored = await read_policy(session, 'C1')
                    assert stored['draft'] == winners[0]['draft']
                    assert stored['active'] is None
        finally:
            await engine.dispose()
    asyncio.run(work())


def test_actual_asgi_draft_routes_validate_identity_and_strict_revision(tmp_path,monkeypatch):
    import httpx
    from fastapi import FastAPI, Request
    from app.core.database import get_db

    async def work():
        engine = create_async_engine('sqlite+aiosqlite:///' + str(tmp_path / 'routes.db'))
        factory = async_sessionmaker(engine, expire_on_commit=False)
        async with engine.begin() as conn:
            await conn.run_sync(models.Base.metadata.create_all)
        async with factory() as session:
            session.add(models.Company(code='C1', name='One'))
            await session.commit()
        from test_permission_editor_integration import Source,ACTOR
        from test_management_directory import install
        source=Source(root=True);install(source);monkeypatch.setattr(auth,'db',source)
        app = FastAPI()
        async def database():
            async with factory() as session: yield session
        app.dependency_overrides[get_db] = database
        @app.middleware('http')
        async def fake_identity(request: Request, call_next):
            request.state.auth_user = {**source.cached_actor,'role':request.headers.get('x-fixture-role','employee')}
            return await call_next(request)
        app.include_router(auth.router, prefix='/auth')
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://fixture') as client:
                url = '/auth/companies/C1/permission-policy'
                for role in ('employee', 'admin'):
                    headers = {'x-fixture-role': role}
                    assert (await client.get(url, headers=headers)).status_code == 403
                    assert (await client.put(url + '/draft', headers=headers, json={
                        'expected_revision': 0, 'configuration': config()})).status_code == 403
                root = {'x-fixture-role': 'super_admin'}
                for bad_revision in (True, '0', 0.5):
                    assert (await client.put(url + '/draft', headers=root, json={
                        'expected_revision': bad_revision, 'configuration': config()})).status_code == 422
                response = await client.put(url + '/draft', headers=root, json={
                    'expected_revision': 0, 'configuration': config()})
                assert response.status_code == 200 and response.json()['active'] is None
                assert response.json()['authorization_changed'] is False
                assert (await client.get(url, headers=root)).json()['draft'] == config()
                assert (await client.put(url + '/draft', headers=root, json={
                    'expected_revision': 0, 'configuration': config()})).status_code == 409
                assert (await client.post(url + '/activate', headers=root, json={})).status_code == 422
                assert (await client.get('/auth/companies/missing/permission-policy', headers=root)).status_code == 404
        finally:
            await engine.dispose()
    asyncio.run(work())

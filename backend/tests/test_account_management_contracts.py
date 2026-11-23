"""Actual account-management handlers, synthetic source records only."""
import asyncio
import copy
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from app.routes import auth
from test_notification_revocation import setup_source, request, ACTOR, EMAIL

@pytest.mark.parametrize('permissions', [
    {'المبيعات': None}, {'المبيعات': {'إضافة': 'true'}}, {'المبيعات': {'إضافة': 1}},
    {'المبيعات': {'': True}}, {'': {}}, {'المبيعات': {1: True}},
])
def test_invalid_permission_map_cannot_be_committed(permissions, monkeypatch):
    state, _, _ = setup_source(monkeypatch); original = copy.deepcopy(state)
    async def run():
        with pytest.raises(HTTPException) as error:
            await auth.update_user_permissions(auth.PermissionsUpdateModel(email=EMAIL, permissions=permissions), request(ACTOR))
        assert error.value.status_code == 400
        assert state == original
    asyncio.run(run())

@pytest.mark.parametrize('role,job,allowed', [('employee','200',False), ('employee','201',False),
    ('employee','1',False), ('admin','201',True), ('admin','1',True), ('super_admin','99',True), ('','201',True), ('','200',False)])
def test_company_user_list_uses_effective_role_not_stale_job_code(role,job,allowed,tmp_path,monkeypatch):
    from test_permission_editor_integration import fixture, ACTOR, TARGET
    from test_management_directory import install
    async def run():
        async with fixture(tmp_path,monkeypatch,active=False) as (client,source,_,_):
            install(source);source.patch(ACTOR,role=role,job_code=job)
            source.patch(TARGET,branch_code='B1',allowed_branches=['B1','B2'])
            response=await client.get('/auth/company-users?company_code=C1')
            assert response.status_code==(200 if allowed else 403),response.text
            if allowed:
                row=next(row for row in response.json() if row['email']==TARGET)
                assert row['uid']=='target-uid' and row['allowed_branches']==['B1','B2']
                assert row['startup_branch_code']==row['branch_code']=='B1' and row['role']=='employee'
    asyncio.run(run())

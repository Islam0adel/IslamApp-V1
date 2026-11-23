"""Account-list tenant boundaries and valid permission-map replacement."""
import asyncio
from fastapi import HTTPException
import pytest
from app.routes import auth
from test_notification_revocation import setup_source, request, ACTOR, EMAIL

@pytest.mark.parametrize('permissions', [{}, {'المبيعات': {'إضافة': True, 'تعديل': False}}])
def test_valid_map_is_preserved_exactly(permissions, tmp_path, monkeypatch):
    from test_permission_editor_integration import fixture, TARGET
    async def run():
        async with fixture(tmp_path,monkeypatch,active=False) as (client,source,_,_):
            response=await client.post('/auth/update-permissions',json={'email':TARGET,'permissions':permissions})
            assert response.status_code==200,response.text
            assert source.records[TARGET]['permissions']==permissions
            assert source.records[TARGET]['allowed_branches']==['B2']
    asyncio.run(run())

def test_admin_cannot_select_another_company_for_user_list(tmp_path,monkeypatch):
    from test_permission_editor_integration import fixture
    from test_management_directory import install
    async def run():
        async with fixture(tmp_path,monkeypatch,active=False) as (client,source,_,_):
            install(source)
            response=await client.get('/auth/company-users?company_code=C2')
            assert response.status_code==200,response.text
            assert source.scans==['C1']
    asyncio.run(run())

def test_admin_without_company_cannot_list_global_users(tmp_path,monkeypatch):
    from test_permission_editor_integration import fixture, ACTOR
    from test_management_directory import install
    async def run():
        async with fixture(tmp_path,monkeypatch,active=False) as (client,source,_,_):
            install(source);source.patch(ACTOR,company_code='')
            response=await client.get('/auth/company-users')
            assert response.status_code==403 and not source.scans
    asyncio.run(run())

def test_root_can_list_all_companies_without_filter(tmp_path,monkeypatch):
    from test_permission_editor_integration import fixture
    from test_management_directory import install
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,_,_):
            install(source)
            response=await client.get('/auth/company-users')
            assert response.status_code==200,response.text
            assert len(response.json())==2 and source.scans==[None]
    asyncio.run(run())

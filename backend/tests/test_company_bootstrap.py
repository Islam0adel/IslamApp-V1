"""New-company bootstrap gates, using real routes/middleware/SQL and fake identity."""
import asyncio
import copy
from contextlib import asynccontextmanager
from datetime import datetime
import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy import select, update, func
from app.core import models, auth_middleware as middleware, company_policy_store as policy
from app.core.database import get_db
from app.routes import auth
from test_permission_editor_integration import fixture as source_fixture, ACTOR, TARGET, Reference
from test_permission_directory import install, Query

EMPTY={'company_permissions':{},'admin_profiles':{}}

@asynccontextmanager
async def fixture(tmp_path,monkeypatch):
    async with source_fixture(tmp_path,monkeypatch,root=True,active=False) as (_,source,factory,_):
        install(source,monkeypatch)
        monkeypatch.setattr(Query,'get',lambda self:list(self.stream()),raising=False)
        monkeypatch.setattr(Reference,'update',lambda self,values:self.source.patch(self.email,**values),raising=False)
        monkeypatch.setattr(middleware,'AsyncSessionLocal',factory)
        monkeypatch.setattr(middleware,'firebase_db',source)
        monkeypatch.setattr(middleware.admin_auth,'verify_id_token',lambda *args,**kwargs:{'uid':'actor-uid','email':ACTOR})
        middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()
        app=FastAPI();app.middleware('http')(middleware.authenticate_http_request)
        async def database():
            async with factory() as session: yield session
        app.dependency_overrides[get_db]=database;app.include_router(auth.router,prefix='/auth')
        probes=[]
        @app.get('/business-probe')
        async def probe(): probes.append(True);return {'reached':True}
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture',headers={'authorization':'Bearer synthetic-token'}) as client:
                yield client,source,factory,probes
        finally:
            middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()

async def create(client,**extra):
    response=await client.post('/auth/companies/add?admin_job_code=99',json={'code':'NEW','name':'New fixture',**extra})
    assert response.status_code==200,response.text
    assert response.json()['requires_permission_review'] is True

@pytest.mark.parametrize('profile_claim',[False,True,None])
def test_new_company_route_marks_review_without_converting_existing_companies(profile_claim,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,_,factory,_):
            await create(client,requires_permission_review=profile_claim)
            async with factory() as session:
                assert (await session.get(models.Company,'NEW')).requires_permission_review is True
                assert (await session.get(models.Company,'C1')).requires_permission_review is False
                assert await session.get(models.CompanyPermissionPolicy,'NEW') is None
            response=await client.get('/auth/companies/NEW/permission-policy')
            assert response.status_code==200,response.text
            assert response.json()['status']=='initial_review_required' and response.json()['active'] is None
            response=await client.get('/auth/companies/all?admin_job_code=99')
            flags={row['code']:row['requires_permission_review'] for row in response.json()}
            assert flags=={'C1':False,'NEW':True}
    asyncio.run(run())


def test_root_draft_save_and_status_toggle_cannot_unlock_bootstrap(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,_,factory,_):
            await create(client)
            response=await client.put('/auth/companies/NEW/permission-policy/draft',json={'expected_revision':0,'configuration':EMPTY})
            assert response.status_code==200,response.text
            assert response.json()['status']=='initial_review_required' and response.json()['active'] is None
            for enabled in (False,True):
                response=await client.post('/auth/companies/toggle',json={'code':'NEW','is_active':enabled,'admin_job_code':'99'})
                assert response.status_code==200,response.text
                async with factory() as session:
                    company=await session.get(models.Company,'NEW')
                    assert company.requires_permission_review is True and company.is_active is enabled
            async with factory() as session:
                with pytest.raises(policy.CompanyReviewRequired):await policy.active_policy_configuration(session,'NEW')
    asyncio.run(run())

@pytest.mark.parametrize('path,method,payload',[
    ('/business-probe','GET',None),('/auth/session-profile','GET',None),
    ('/auth/company-users','GET',None),('/auth/permission-editor-targets?company_code=NEW','GET',None),
    ('/auth/admin/edit-user','PUT',{'email':TARGET,'name':'should not land'}),
])
def test_new_company_member_cannot_reach_legacy_business_or_admin_handlers(path,method,payload,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,probes):
            await create(client)
            # Separate identity phase, not a cache-revocation test.
            source.patch(ACTOR,role='admin',company_code='NEW',requires_permission_review=False,
                         permissions={'المبيعات':{'حذف':True}},allowed_branches=['all'])
            middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()
            response=await client.request(method,path,json=payload)
            assert response.status_code==403,response.text
            assert response.json()['code']=='company_review_required'
            assert not probes and not source.query_companies and source.records[TARGET].get('name') is None
            # An accidentally written active row does not clear the company gate.
            async with factory() as session:
                session.add(models.CompanyPermissionPolicy(company_code='NEW',revision=1,active_revision=1,active=copy.deepcopy(EMPTY)))
                await session.commit()
            response=await client.get('/business-probe')
            assert response.status_code==403 and not probes
    asyncio.run(run())


def test_current_sql_bootstrap_gate_is_not_hidden_by_cached_legacy_profile(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,probes):
            source.patch(ACTOR,role='admin',requires_permission_review=True)
            assert (await client.get('/business-probe')).status_code==200
            assert len(probes)==1
            async with factory() as session:
                await session.execute(update(models.Company).where(models.Company.code=='C1').values(requires_permission_review=True));await session.commit()
            response=await client.get('/business-probe')
            assert response.status_code==403 and response.json()['code']=='company_review_required' and len(probes)==1
    asyncio.run(run())

@pytest.mark.parametrize('kind',['new','draft','active'])
def test_company_code_change_cannot_discard_new_or_reviewed_policy_state(kind,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            if kind=='new':await create(client);code='NEW'
            else:
                code='C1'
                async with factory() as session:
                    session.add(models.CompanyPermissionPolicy(company_code=code,revision=1,
                        draft=copy.deepcopy(EMPTY),active=copy.deepcopy(EMPTY) if kind=='active' else None,
                        active_revision=1 if kind=='active' else None));await session.commit()
            response=await client.put('/auth/companies/update',json={'old_code':code,'new_code':'RENAMED','new_name':'Renamed fixture','admin_job_code':'99'})
            assert response.status_code==409,response.text
            assert not source.query_companies
            async with factory() as session:
                assert await session.get(models.Company,code) is not None
                assert await session.get(models.Company,'RENAMED') is None
            # A normal name edit stays available and preserves all policy flags.
            response=await client.put('/auth/companies/update',json={'old_code':code,'new_code':code,'new_name':'New name','admin_job_code':'99'})
            assert response.status_code==200,response.text
            async with factory() as session:
                company=await session.get(models.Company,code)
                assert company.name=='New name' and company.requires_permission_review is (kind=='new')
    asyncio.run(run())


def test_root_can_prepare_new_company_but_cannot_bypass_activation_contract(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,_,_,probes):
            await create(client)
            assert (await client.get('/business-probe')).status_code==200
            assert probes==[True]
            assert (await client.post('/auth/companies/NEW/permission-policy/activate',json={})).status_code==422
    asyncio.run(run())

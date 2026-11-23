"""Actual directory HTTP/SQL authorization with an explicitly synthetic source query."""
import asyncio
import copy
import pytest
from sqlalchemy import update
from app.core import models
from app.core.sync import ConnectionManager
from test_permission_editor_integration import fixture, Snapshot, ACTOR, TARGET

class Query:
    def __init__(self,source,company=None): self.source=source; self.company=company
    def document(self,email): return self.source.document(email)
    def where(self,field,operator,value):
        assert (field,operator)==('company_code','==')
        return Query(self.source,value)
    def stream(self):
        self.source.query_companies.append(self.company)
        for email in list(self.source.records):
            if self.company is None or self.source.records[email].get('company_code')==self.company:
                yield Snapshot(self.source,email)
        if self.source.after_scan:
            hook=self.source.after_scan; self.source.after_scan=None; hook()


def install(source,monkeypatch):
    source.query_companies=[]; source.after_scan=None
    def collection(name): assert name=='users'; return Query(source)
    monkeypatch.setattr(source,'collection',collection)


def test_current_directory_is_minimal_company_scoped_and_delegation_only(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,_):
            install(source,monkeypatch)
            source.patch(TARGET,name='Target',phone='private-phone',username='private-login',salary=999,
                         contacts=['private-contact'],permissions={'secret':{'right':True}})
            source.records['foreign@example.invalid']={'uid':'foreign','company_code':'C2','role':'employee'}
            response=await client.get('/auth/permission-editor-targets?company_code=C2')
            assert response.status_code==200,response.text
            value=response.json(); assert value['company_code']=='C1' and value['company_policy_revision']==1
            assert {v['email'] for v in value['users']}=={ACTOR,TARGET}
            user=next(v for v in value['users'] if v['email']==TARGET)
            assert set(user)=={'email','uid','name','company_code','company_name','job_code','job_title','role','status','is_active'}
            assert not any(private in response.text for private in ['private-phone','private-login','private-contact','secret'])
            assert source.query_companies==['C1']
            assert source.records[ACTOR]['permissions']=={} and source.records[ACTOR]['allowed_branches']==['B1']
    asyncio.run(run())

@pytest.mark.parametrize('change',['blocked','uid','demoted','company','no-delegation','company-disabled','invalid-revision'])
def test_directory_rechecks_current_actor_and_policy_not_cached_claims(change,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            install(source,monkeypatch)
            if change=='blocked': source.patch(ACTOR,is_active=False)
            if change=='uid': source.patch(ACTOR,uid='replaced')
            if change=='demoted': source.patch(ACTOR,role='employee')
            if change=='company': source.patch(ACTOR,company_code='C2')
            async with factory() as session:
                if change=='no-delegation':
                    row=await session.get(models.CompanyPermissionPolicy,'C1')
                    configuration=copy.deepcopy(row.active)
                    configuration['admin_profiles']['actor-uid'].update(delegable_permissions={},delegable_branches=[])
                    row.active=configuration
                if change=='company-disabled': await session.execute(update(models.Company).where(models.Company.code=='C1').values(is_active=False))
                if change=='invalid-revision': await session.execute(update(models.CompanyPermissionPolicy).where(models.CompanyPermissionPolicy.company_code=='C1').values(active_revision=None))
                await session.commit()
            response=await client.get('/auth/permission-editor-targets?company_code=C1')
            assert response.status_code in (403,404,503),response.text
            assert 'users' not in response.json() and not source.query_companies
    asyncio.run(run())

@pytest.mark.parametrize('change',['blocked','role','uid','company','version'])
def test_directory_discards_scan_when_actor_changes_during_it(change,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,_):
            install(source,monkeypatch)
            values={'blocked':{'is_active':False},'role':{'role':'employee'},'uid':{'uid':'replacement'},
                    'company':{'company_code':'C2'},'version':{'name':'new actor name'}}[change]
            source.after_scan=lambda:source.patch(ACTOR,**values)
            response=await client.get('/auth/permission-editor-targets?company_code=C1')
            assert response.status_code in (403,409),response.text
            assert 'users' not in response.json()
    asyncio.run(run())

@pytest.mark.parametrize('requested',['','C1','C2'])
def test_root_can_request_global_or_explicit_company_choices(requested,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,factory,_):
            install(source,monkeypatch)
            async with factory() as session:
                session.add(models.Company(code='C2',name='Two',is_active=True)); await session.commit()
            source.records['foreign@example.invalid']={'uid':'foreign','company_code':'C2','role':'employee'}
            response=await client.get('/auth/permission-editor-targets',params={'company_code':requested})
            assert response.status_code==200,response.text
            value=response.json(); assert value['company_code']==requested
            expected={ACTOR,TARGET,'foreign@example.invalid'} if not requested else ({ACTOR,TARGET} if requested=='C1' else {'foreign@example.invalid'})
            assert {v['email'] for v in value['users']}==expected
            assert source.query_companies==[requested or None]
    asyncio.run(run())

@pytest.mark.parametrize('allowed',[True,False])
def test_legacy_employee_requires_explicit_editor_flag(allowed,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,active=False) as (client,source,_,_):
            install(source,monkeypatch)
            source.patch(ACTOR,role='employee',permissions={'صلاحيات عامة':{'صفحة الصلاحيات(الاعدادات)':allowed}})
            response=await client.get('/auth/permission-editor-targets?company_code=C1')
            assert response.status_code==(200 if allowed else 403),response.text
    asyncio.run(run())


def test_query_failure_is_not_reported_as_empty_directory(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,_):
            install(source,monkeypatch)
            def broken(): raise RuntimeError('private source transport detail')
            source.after_scan=broken
            response=await client.get('/auth/permission-editor-targets?company_code=C1')
            assert response.status_code==503 and 'private' not in response.text and 'users' not in response.json()
    asyncio.run(run())


def test_directory_hint_has_no_account_payload_and_only_reaches_editor_candidates():
    class Socket:
        def __init__(self,broken=False): self.sent=[]; self.broken=broken
        async def send_json(self,value):
            if self.broken: raise RuntimeError('closed')
            self.sent.append(value)
    async def run():
        manager=ConnectionManager()
        admin,root,legacy,employee,foreign,dead=[Socket() for _ in range(6)]; dead.broken=True
        manager.active_connections={'C1':{admin,root,legacy,employee,dead},'C2':{foreign}}
        manager.connection_profiles={admin:{'role':'admin'},root:{'role':'super_admin'},
            legacy:{'role':'employee','permissions':{'صلاحيات عامة':{'صفحة الصلاحيات(الاعدادات)':True}}},
            employee:{'role':'employee'},foreign:{'role':'admin'},dead:{'role':'admin'}}
        await manager.notify_user_directory_changed('C1')
        expected=[{'type':'user_directory_changed','data':{'company_code':'C1'},'suppress_notification':True}]
        assert admin.sent==root.sent==legacy.sent==expected
        assert not employee.sent and not foreign.sent
        assert dead not in manager.active_connections['C1']
    asyncio.run(run())


def test_directory_and_editor_through_installed_authentication_middleware(tmp_path,monkeypatch):
    import httpx
    from fastapi import FastAPI
    from app.core import auth_middleware as middleware
    from app.core.database import get_db
    from app.routes import auth
    async def run():
        async with fixture(tmp_path,monkeypatch) as (_,source,factory,_):
            install(source,monkeypatch)
            monkeypatch.setattr(middleware,'AsyncSessionLocal',factory)
            monkeypatch.setattr(middleware,'firebase_db',source)
            monkeypatch.setattr(middleware.admin_auth,'verify_id_token',lambda *args,**kwargs:{'uid':'actor-uid','email':ACTOR})
            middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()
            app=FastAPI();app.middleware('http')(middleware.authenticate_http_request)
            async def database():
                async with factory() as session: yield session
            app.dependency_overrides[get_db]=database;app.include_router(auth.router,prefix='/auth')
            try:
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture') as client:
                    assert (await client.get('/auth/permission-editor-targets?company_code=C1')).status_code==401
                    client.headers['authorization']='Bearer synthetic-token'
                    response=await client.get('/auth/permission-editor-targets?company_code=C2')
                    assert response.status_code==200,response.text
                    assert response.json()['company_code']=='C1'
                    assert {v['email'] for v in response.json()['users']}=={ACTOR,TARGET}
                    response=await client.get('/auth/permission-editor/'+TARGET)
                    assert response.status_code==200,response.text
                    assert response.json()['delegable_branches']==['B2']
                    assert source.records[ACTOR]['allowed_branches']==['B1'] and source.records[ACTOR]['permissions']=={}
                    source.patch(ACTOR,uid='replaced-owner')
                    assert (await client.get('/auth/permission-editor-targets?company_code=C1')).status_code==401
                    source.patch(ACTOR,uid='actor-uid',is_active=False)
                    assert (await client.get('/auth/permission-editor-targets?company_code=C1')).status_code==403
                    source.patch(ACTOR,is_active=True)
                    # Owned account mutations invalidate this worker's cache.
                    # Cross-worker negative-cache recovery is a separate check.
                    middleware.invalidate_profile_cache(ACTOR)
                    async with factory() as session:
                        row=await session.get(models.CompanyPermissionPolicy,'C1')
                        configuration=copy.deepcopy(row.active)
                        configuration['admin_profiles']['actor-uid'].update(delegable_permissions={},delegable_branches=[])
                        row.active=configuration;row.active_revision=2;await session.commit()
                    assert (await client.get('/auth/permission-editor-targets?company_code=C1')).status_code==403
                    assert source.query_companies==['C1']
            finally:
                middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()
    asyncio.run(run())

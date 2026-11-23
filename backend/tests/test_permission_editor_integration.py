"""ASGI permission-editor integration: actual routes/SQL, synthetic source CAS.

The source fixture models versioned transaction retries; it is not a live
Firestore/emulator test. SQL lock behavior has separate PostgreSQL coverage.
"""
import asyncio
import copy
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import httpx
import pytest
from fastapi import FastAPI, Request
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models, permission_editor as editor
from app.core.database import get_db
from app.routes import auth

ACTOR='manager@example.invalid'; TARGET='target@example.invalid'
VIEW={'المبيعات':{'معاينة':True}}
ALL={'المبيعات':{'معاينة':True,'إضافة':True,'تعديل':True,'حذف':True},
     'الموارد البشرية':{'canViewEmployees':True,'canViewSalaryAmounts':True,'canViewOwnHRData':True}}

class Snapshot:
    def __init__(self,source,email):
        self.id=email; self.reference=Reference(source,email)
        self.exists=email in source.records
        self.data=copy.deepcopy(source.records.get(email))
        self.update_time=datetime(2026,11,22,tzinfo=timezone.utc)+timedelta(microseconds=source.versions.get(email,0))
    def to_dict(self): return copy.deepcopy(self.data)

class Reference:
    def __init__(self,source,email): self.source=source; self.email=email
    def get(self,transaction=None):
        snap=Snapshot(self.source,self.email)
        if transaction is not None: transaction.reads[self.email]=self.source.versions.get(self.email,0)
        return snap

class Source:
    def __init__(self,root=False):
        self.records={ACTOR:{'uid':'actor-uid','role':'super_admin' if root else 'admin',
            'company_code':'C1','allowed_branches':['B1'],'permissions':{},'is_active':True,'status':'active'},
            TARGET:{'uid':'target-uid','role':'employee','company_code':'C1','allowed_branches':['B2'],
                'branch_code':'B2','permissions':{},'status':'active','is_active':True}}
        self.versions={ACTOR:1,TARGET:1}; self.before_commit=None; self.commits=0; self.attempts=0
        self.cached_actor={**copy.deepcopy(self.records[ACTOR]),'email':ACTOR}
    def collection(self,name): assert name=='users'; return self
    def document(self,email): return Reference(self,email)
    def patch(self,document_id,**values):
        self.records[document_id].update(copy.deepcopy(values)); self.versions[document_id]+=1

class Transaction:
    def __init__(self,source): self.source=source; self.reads={}; self.writes=[]
    def update(self,ref,values): self.writes.append((ref.email,copy.deepcopy(values)))

def transaction_runner(source,callback):
    for _ in range(5):
        source.attempts+=1; transaction=Transaction(source); result=callback(transaction)
        if source.before_commit is not None:
            hook=source.before_commit; source.before_commit=None; hook()
        if any(source.versions.get(email,0)!=version for email,version in transaction.reads.items()): continue
        for email,values in transaction.writes:
            # The real SDK resolves SERVER_TIMESTAMP. The fixture needs only a
            # source-record timestamp and independent version increment.
            values['updated_at']=datetime(2026,11,22,tzinfo=timezone.utc)
            source.patch(email,**values)
        source.commits+=1
        return result
    raise RuntimeError('synthetic source retry budget exhausted')

@asynccontextmanager
async def fixture(tmp_path,monkeypatch,*,root=False,active=True,delegation=None,branches=None,provided_factory=None):
    engine = None
    factory = provided_factory
    if factory is None:
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'editor.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn: await conn.run_sync(models.Base.metadata.create_all)
    configuration={'company_permissions':copy.deepcopy(ALL),'admin_profiles':{
        'actor-uid':{'operating_permissions':{},'delegable_permissions':copy.deepcopy(VIEW if delegation is None else delegation),
                     'delegable_branches':['B2'] if branches is None else branches},
        'another-private-admin':{'operating_permissions':{},'delegable_permissions':{}}}}
    async with factory() as db:
        db.add(models.Company(code='C1',name='One',is_active=True))
        db.add_all([models.Branch(company_code='C1',code=code,name=code) for code in ['B1','B2','B3']])
        db.add(models.Employee(company_code='C1',code='E1',name='Linked fixture',branch_code='B1',user_uid='target-uid'))
        db.add(models.Employee(company_code='C1',code='E2',name='Other fixture',branch_code='B2'))
        if active: db.add(models.CompanyPermissionPolicy(company_code='C1',revision=1,active_revision=1,active=configuration))
        await db.commit()
    source=Source(root=root); notices=[]
    monkeypatch.setattr(auth,'db',source); monkeypatch.setattr(editor,'run_source_transaction',transaction_runner)
    async def notify(*args): notices.append(args)
    monkeypatch.setattr(auth,'_notify_permissions_changed',notify)
    app=FastAPI()
    @app.middleware('http')
    async def identity(request: Request,call_next):
        request.state.auth_user=copy.deepcopy(source.cached_actor)
        return await call_next(request)
    async def database():
        async with factory() as db: yield db
    app.dependency_overrides[get_db]=database
    app.include_router(auth.router,prefix='/auth')
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture') as client:
            yield client,source,factory,notices
    finally:
        if engine is not None: await engine.dispose()

async def load(client):
    response=await client.get('/auth/permission-editor/'+TARGET)
    assert response.status_code==200,response.text
    value=response.json()
    return value,{'email':TARGET,'permissions':copy.deepcopy(value['permissions']),
        'expected_target_uid':value['uid'],'expected_profile_version':value['profile_version'],
        'expected_policy_revision':value['company_policy_revision']}


def test_real_scope_read_and_write_use_delegation_not_operating_rights(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,notices):
            profile,data=await load(client)
            assert profile['delegable_permissions']==VIEW and profile['delegable_branches']==['B2']
            assert profile['allowed_branches']==['B2'] and 'another-private-admin' not in str(profile)
            assert source.records[ACTOR]['permissions']=={} and source.records[ACTOR]['allowed_branches']==['B1']
            data['permissions']=VIEW
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==200,response.text
            assert source.records[TARGET]['permissions']==VIEW and source.commits==1
            assert source.records[TARGET]['allowed_branches']==['B2'] and source.records[TARGET]['branch_code']=='B2'
            assert notices==[('C1',TARGET)]
    asyncio.run(run())

@pytest.mark.parametrize('case',['ceiling','delegation','branch-scope','source-claims','missing-version',
    'stale-version','stale-policy','wrong-uid','role-demoted','actor-blocked','actor-uid',
    'target-admin','target-company','empty-branches','malformed-flags','unknown-employee'])
def test_actual_scope_write_rejects_invalid_or_stale_authority(case,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            _,data=await load(client); data['permissions']=VIEW; expected=403
            if case=='ceiling': data['permissions']={'التكويد':{'حذف':True}}
            if case=='delegation': data['permissions']={'المبيعات':{'حذف':True}}
            if case=='branch-scope': data['allowed_branches']=['B3']; data['startup_branch_code']='B3'
            if case=='source-claims':
                source.records[ACTOR]['delegable_permissions']=copy.deepcopy(ALL)
                source.records[ACTOR]['delegable_branches']=['all']
                data['permissions']={'المبيعات':{'حذف':True}}
            if case=='missing-version': data.pop('expected_profile_version'); expected=409
            if case=='stale-version': data['expected_profile_version']='old'; expected=409
            if case=='stale-policy': data['expected_policy_revision']=0; expected=409
            if case=='wrong-uid': data['expected_target_uid']='other'; expected=409
            if case=='role-demoted': source.patch(ACTOR,role='employee')
            if case=='actor-blocked': source.patch(ACTOR,is_active=False)
            if case=='actor-uid': source.patch(ACTOR,uid='someone-else')
            if case=='target-admin': source.patch(TARGET,role='admin'); expected=409
            if case=='target-company': source.patch(TARGET,company_code='C2'); expected=404
            if case=='empty-branches': data['allowed_branches']=[]; expected=400
            if case=='malformed-flags': data['permissions']={'المبيعات':{'معاينة':1}}; expected=400
            if case=='unknown-employee': data['hr_viewable_employees']=['unknown']; expected=400
            before=copy.deepcopy(source.records[TARGET])
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==expected,response.text
            assert source.records[TARGET]==before and source.commits==0 and not notices
    asyncio.run(run())

@pytest.mark.parametrize('change',['actor-blocked','actor-demoted','target-version','target-uid'])
def test_actual_source_transaction_retry_rechecks_actor_and_target(change,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,notices):
            _,data=await load(client); data['permissions']=VIEW
            def racing_change():
                if change=='actor-blocked': source.patch(ACTOR,is_active=False)
                if change=='actor-demoted': source.patch(ACTOR,role='employee')
                if change=='target-version': source.patch(TARGET,name='Newer name')
                if change=='target-uid': source.patch(TARGET,uid='new-account')
            source.before_commit=racing_change
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code in (403,409),response.text
            assert source.attempts==2 and source.commits==0 and not notices
            assert source.records[TARGET]['permissions']=={}
    asyncio.run(run())

@pytest.mark.parametrize('kind',['permission-affects-foreign-branch','branch-expands-undelegated-right',
                                  'hr-expands-undelegated-right','wildcard-is-future-reach'])
def test_both_permission_and_data_scope_axes_are_enforced(kind,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,branches=['B2','B3']) as (client,source,_,notices):
            if kind=='permission-affects-foreign-branch': source.patch(TARGET,allowed_branches=['B1'],branch_code='B1')
            if kind=='branch-expands-undelegated-right': source.patch(TARGET,permissions={'المبيعات':{'حذف':True}})
            if kind=='hr-expands-undelegated-right':
                source.patch(TARGET,permissions={'الموارد البشرية':{'canViewEmployees':True}},hr_viewable_employees=['E1'])
            _,data=await load(client)
            if kind=='permission-affects-foreign-branch': data['permissions']=VIEW
            if kind=='branch-expands-undelegated-right': data['allowed_branches']=['B2','B3']
            if kind=='hr-expands-undelegated-right': data['hr_viewable_employees']=[]
            if kind=='wildcard-is-future-reach': data['allowed_branches']=['all']
            before=copy.deepcopy(source.records[TARGET])
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==403,response.text
            assert source.records[TARGET]==before and not notices
    asyncio.run(run())


def test_root_still_obeys_ceiling_and_can_explicitly_repair_target_scope(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,_,notices):
            source.patch(TARGET,allowed_branches=None)
            _,data=await load(client); data.update(permissions=VIEW,allowed_branches=['B3'],startup_branch_code='B3')
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==200,response.text
            assert source.records[TARGET]['allowed_branches']==['B3'] and source.records[TARGET]['branch_code']=='B3'
            _,data=await load(client); data['permissions']={'unknown':{'x':True}}
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==403 and len(notices)==1
    asyncio.run(run())


def test_legacy_company_keeps_old_editor_shape_but_uses_current_source_transaction(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,active=False) as (client,source,_,notices):
            response=await client.post('/auth/update-permissions',json={'email':TARGET,'permissions':VIEW,'allowed_branches':['all']})
            assert response.status_code==200,response.text
            assert response.json()['company_policy_active'] is False
            assert source.records[TARGET]['permissions']==VIEW and source.records[TARGET]['allowed_branches']==['all']
            assert source.commits==1 and len(notices)==1
    asyncio.run(run())

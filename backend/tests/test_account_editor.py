"""Actual metadata routes, actual isolated SQL, synthetic source transactions."""
import asyncio
import copy
import pytest
from app.core import models
from test_permission_editor_integration import fixture, ACTOR, TARGET, Snapshot

CATEGORY='إدارة المستخدمين'
EDIT='تعديل'
STATUS='تغيير حالة الحساب'

async def grant(factory,rights,*,delegated=None):
    async with factory() as db:
        row=await db.get(models.CompanyPermissionPolicy,'C1')
        value=copy.deepcopy(row.active)
        value['company_permissions'][CATEGORY]={EDIT:True,STATUS:True}
        value['admin_profiles']['actor-uid']['operating_permissions']={CATEGORY:{key:True for key in rights}}
        value['admin_profiles']['actor-uid']['delegable_permissions']={CATEGORY:{key:True for key in (delegated or [])}}
        row.active=value;await db.commit()

async def load(client):
    response=await client.get('/auth/user-editor/'+TARGET)
    assert response.status_code==200,response.text
    value=response.json()
    return value,{'email':TARGET,'expected_target_uid':value['uid'],
        'expected_profile_version':value['profile_version'],
        'expected_policy_revision':value['company_policy_revision']}

@pytest.mark.parametrize('rights',[[EDIT],[STATUS],[EDIT,STATUS]])
def test_actual_editor_separates_metadata_and_status(tmp_path,monkeypatch,rights):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            await grant(factory,rights)
            source.patch(TARGET,name='Target',phone_number='01000000000',username='existing',hr_viewable_employees=['E2'])
            initial=copy.deepcopy(source.records[TARGET])
            value,payload=await load(client)
            assert value['can_edit']==(EDIT in rights) and value['can_change_status']==(STATUS in rights)
            assert value['can_change_role'] is False
            assert 'permissions' not in value and 'hr_viewable_employees' not in value
            if EDIT in rights:
                assert value['phone_number']=='01000000000'
                assert value['branch_choices']==[{'code':'B2','name':'B2'}]
                payload.update(name='Changed',phone_number='01000000000',username='existing',branch_code='B2')
            else:
                assert 'phone_number' not in value and 'username' not in value and not value['branch_choices']
            if STATUS in rights:payload.update(status='suspended',is_active=False)
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==200,response.text
            state=source.records[TARGET]
            assert state['permissions']==initial['permissions'] and state['allowed_branches']==['B2']
            assert state['hr_viewable_employees']==['E2'] and source.commits==1 and notices==[('C1',TARGET)]
            async with factory() as db:assert (await db.get(models.Employee,1)).branch_code=='B1'
    asyncio.run(run())

@pytest.mark.parametrize('case',['delegation-only','raw-source','metadata-only-status','status-only-metadata',
    'admin-target','root-target','other-company','actor-blocked','actor-uid','company-disabled',
    'role-change','missing-version','missing-uid','wrong-uid','stale-version','stale-policy',
    'branch-outside','malformed-branches','empty-branches','unbound-activation','reset-via-status'])
def test_actual_write_rejects_unavailable_or_stale_authority(tmp_path,monkeypatch,case):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            await grant(factory,[EDIT,STATUS])
            _,payload=await load(client);payload['name']='Must not save';expected=403
            if case=='delegation-only':await grant(factory,[],delegated=[EDIT,STATUS])
            if case=='raw-source':
                await grant(factory,[]);source.patch(ACTOR,permissions={CATEGORY:{EDIT:True,STATUS:True}})
            if case=='metadata-only-status':await grant(factory,[EDIT]);payload['status']='suspended'
            if case=='status-only-metadata':await grant(factory,[STATUS])
            if case=='admin-target':source.patch(TARGET,role='admin');expected=409
            if case=='root-target':source.patch(TARGET,role='super_admin')
            if case=='other-company':source.patch(TARGET,company_code='C2');expected=404
            if case=='actor-blocked':source.patch(ACTOR,is_active=False)
            if case=='actor-uid':source.patch(ACTOR,uid='replacement')
            if case=='company-disabled':
                async with factory() as db:
                    row=await db.get(models.Company,'C1');row.is_active=False;await db.commit()
            if case=='role-change':payload['role']='admin'
            if case=='missing-version':payload.pop('expected_profile_version');expected=409
            if case=='missing-uid':payload.pop('expected_target_uid');expected=409
            if case=='wrong-uid':payload['expected_target_uid']='replacement';expected=409
            if case=='stale-version':source.patch(TARGET,name='Newer');expected=409
            if case=='stale-policy':payload['expected_policy_revision']=99;expected=409
            if case=='branch-outside':payload['branch_code']='B1';expected=400
            if case in ('malformed-branches','empty-branches'):
                source.patch(TARGET,allowed_branches={} if case=='malformed-branches' else [])
                payload['expected_profile_version']=Snapshot(source,TARGET).update_time.isoformat()
                payload['branch_code']='all';expected=409
            if case=='unbound-activation':
                source.patch(TARGET,uid='',status='pending');_,payload=await load(client);payload['status']='active';expected=409
            if case=='reset-via-status':payload['status']='pending';expected=400
            before=copy.deepcopy(source.records[TARGET])
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==expected,response.text
            assert source.records[TARGET]==before and source.commits==0 and not notices
    asyncio.run(run())

@pytest.mark.parametrize('change',['actor-role','actor-company','actor-uid','actor-status','target-role','target-company','target-uid','target-version'])
def test_source_retry_rechecks_current_accounts(tmp_path,monkeypatch,change):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            await grant(factory,[EDIT]);_,payload=await load(client);payload['name']='Must not save'
            def hook():
                actor={'actor-role':{'role':'employee'},'actor-company':{'company_code':'C2'},
                    'actor-uid':{'uid':'new-uid'},'actor-status':{'status':'suspended'}}
                target={'target-role':{'role':'admin'},'target-company':{'company_code':'C2'},
                    'target-uid':{'uid':'new-uid'},'target-version':{'name':'Newer'}}
                source.patch(ACTOR if change in actor else TARGET,**(actor.get(change) or target[change]))
            source.before_commit=hook
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code in (403,404,409),response.text
            assert source.records[TARGET].get('name')!='Must not save' and source.commits==0 and not notices
    asyncio.run(run())

@pytest.mark.parametrize('field,value',[('phone_number','01011111111'),('username','new_user')])
@pytest.mark.parametrize('failure',[False,True])
def test_identifier_queries_never_fail_open(tmp_path,monkeypatch,field,value,failure):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,_,notices):
            source.records['duplicate@example.invalid']={field:value};source.versions['duplicate@example.invalid']=1
            class Query:
                def limit(self,count):assert count==2;return self
                def stream(self):
                    if failure:raise RuntimeError('synthetic lookup failure')
                    return [Snapshot(source,'duplicate@example.invalid')]
            source.where=lambda *args:Query()
            _,payload=await load(client);payload[field]=value
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==(503 if failure else 400),response.text
            assert field not in source.records[TARGET] and source.commits==0 and not notices
    asyncio.run(run())

@pytest.mark.parametrize('field,value',[('is_active','false'),('expected_target_uid',42),('expected_profile_version',42),('expected_policy_revision','1')])
def test_editor_versions_and_blocking_flags_are_strict(tmp_path,monkeypatch,field,value):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,_,_):
            _,payload=await load(client);payload.update(name='No',**{field:value})
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==422 and source.commits==0
    asyncio.run(run())


def test_notification_failure_does_not_claim_saved_account_was_rolled_back(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,_,_):
            from app.routes import auth
            async def fail(*args):raise RuntimeError('synthetic notification failure')
            monkeypatch.setattr(auth,'_notify_permissions_changed',fail)
            _,payload=await load(client);payload['name']='Saved'
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==503 and source.commits==1 and source.records[TARGET]['name']=='Saved'
            assert 'أعد تحميل' in response.json()['detail']
    asyncio.run(run())

@pytest.mark.parametrize('active',[True,False])
def test_actual_auth_middleware_keeps_startup_separate_from_operating_filter(tmp_path,monkeypatch,active):
    import httpx
    from fastapi import FastAPI
    from app.core import auth_middleware as middleware
    from app.core.database import get_db
    from app.routes import auth
    async def run():
        async with fixture(tmp_path,monkeypatch,active=active) as (_,source,factory,_):
            if active:await grant(factory,[EDIT])
            monkeypatch.setattr(middleware,'AsyncSessionLocal',factory)
            monkeypatch.setattr(middleware,'firebase_db',source)
            monkeypatch.setattr(middleware.admin_auth,'verify_id_token',lambda *a,**k:{'uid':'actor-uid','email':ACTOR})
            middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()
            app=FastAPI();app.middleware('http')(middleware.authenticate_http_request)
            async def database():
                async with factory() as session:yield session
            app.dependency_overrides[get_db]=database;app.include_router(auth.router,prefix='/auth')
            try:
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture') as client:
                    assert (await client.get('/auth/user-editor/'+TARGET)).status_code==401
                    client.headers['authorization']='Bearer synthetic-token'
                    _,payload=await load(client);payload['branch_code']='B2'
                    response=await client.put('/auth/admin/edit-user',json=payload)
                    assert response.status_code==(200 if active else 403),response.text
                    assert source.records[ACTOR]['allowed_branches']==['B1']
                    assert source.records[TARGET]['allowed_branches']==['B2']
                    response=await client.post('/auth/admin/add-user',json={'branch_code':'B2'})
                    assert response.status_code==403
                    if active:
                        _,payload=await load(client);payload['branch_code']='B3'
                        assert (await client.put('/auth/admin/edit-user',json=payload)).status_code==400
                        await grant(factory,[])
                        assert (await client.get('/auth/user-editor/'+TARGET)).status_code==403
            finally:
                middleware._PROFILE_CACHE.clear();middleware._COMPANY_CACHE.clear()
    asyncio.run(run())

@pytest.mark.parametrize('pending',[False,True])
def test_unchanged_role_never_clears_permissions_or_blocks_pending_name_edit(tmp_path,monkeypatch,pending):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,_,_):
            source.patch(TARGET,role='admin',permissions={'legacy':{'private':True}})
            if pending:source.patch(TARGET,uid='',status='pending')
            value,payload=await load(client)
            assert value['can_change_role']==(not pending)
            payload.update(name='Renamed',role='admin')
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==200,response.text
            assert source.records[TARGET]['permissions']=={'legacy':{'private':True}}
            assert 'permissions' not in response.json()['updates']
    asyncio.run(run())


def test_status_only_actor_does_not_run_identifier_queries_for_denied_metadata(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            await grant(factory,[STATUS]);_,payload=await load(client)
            payload.update(phone_number='01099999999',username='changed')
            def forbidden(*args):raise AssertionError('denied metadata caused an identifier query')
            source.where=forbidden
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==403 and source.commits==0,response.text
    asyncio.run(run())

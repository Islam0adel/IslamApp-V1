"""Actual review/draft/activation routes with current source and real SQL."""
import asyncio
import copy
import pytest
from sqlalchemy import select
from app.core import models
from app.core.company_policy_store import load_effective_policy_profile
from test_permission_editor_integration import fixture, ACTOR, TARGET
from test_management_directory import install

CONFIG={'company_permissions':{'المبيعات':{'تعديل':True}},'admin_profiles':{'target-uid':{
    'operating_permissions':{'المبيعات':{'إضافة':True}},'delegable_permissions':{'المبيعات':{'تعديل':True}},'delegable_branches':['B2']}}}

@pytest.mark.parametrize('case',['success','initial','no-confirm','stale-source','stale-draft','empty','missing-uid','foreign-admin','blocked-actor','demoted-actor','actor-uid','bad-branches','unknown-branch','duplicate-uid'])
def test_reviewed_activation_never_infers_a_grant(case,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,factory,notices):
            install(source);source.patch(TARGET,role='admin')
            if case=='initial':
                async with factory() as db:
                    company=await db.get(models.Company,'C1');company.requires_permission_review=True;await db.commit()
            review=await client.get('/auth/companies/C1/permission-policy/review')
            assert review.status_code==200,review.text
            assert review.json()['active'] is None
            config=copy.deepcopy(CONFIG)
            if case=='empty':config['admin_profiles']={}
            if case=='missing-uid':config['admin_profiles']['placeholder']=config['admin_profiles'].pop('target-uid')
            response=await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':0,'configuration':config})
            assert response.status_code==200,response.text
            async with factory() as db:
                company=await db.get(models.Company,'C1');assert company.requires_permission_review is (case=='initial')
                row=await db.get(models.CompanyPermissionPolicy,'C1');assert row.active is None
            value=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            expected=200
            if case=='stale-source':source.patch(TARGET,permissions={'المبيعات':{'حذف':True}});expected=409
            if case=='stale-draft':
                await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':1,'configuration':config});expected=409
            if case=='foreign-admin':source.patch(TARGET,company_code='C2');expected=409
            if case=='blocked-actor':source.patch(ACTOR,is_active=False);expected=403
            if case=='demoted-actor':source.patch(ACTOR,role='employee');expected=403
            if case=='actor-uid':source.patch(ACTOR,uid='replacement');expected=403
            if case=='bad-branches':source.patch(TARGET,allowed_branches=[]);value=(await client.get('/auth/companies/C1/permission-policy/review')).json();expected=409
            if case=='unknown-branch':source.patch(TARGET,allowed_branches=['missing']);value=(await client.get('/auth/companies/C1/permission-policy/review')).json();expected=409
            if case=='duplicate-uid':
                source.records['duplicate@example.com']={**source.records[TARGET],'email':'duplicate@example.com'}
                value=(await client.get('/auth/companies/C1/permission-policy/review')).json();expected=409
            if case=='empty':expected=400
            if case=='missing-uid':expected=409
            if case=='no-confirm':expected=400
            response=await client.post('/auth/companies/C1/permission-policy/activate',json={'expected_revision':value['revision'],
                'source_review_token':value['source_review_token'],'confirmed_review':case!='no-confirm'})
            assert response.status_code==expected,response.text
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1');company=await db.get(models.Company,'C1')
                if expected==200:
                    assert row.active==config and row.active_revision==2 and row.reviewed_by_uid=='actor-uid'
                    assert company.requires_permission_review is False
                    profile=await load_effective_policy_profile(db,{**source.records[TARGET],'email':TARGET},role='admin')
                    assert profile['permissions']=={'المبيعات':{'إضافة':True}}
                    assert profile['delegable_permissions']=={'المبيعات':{'إضافة':True,'تعديل':True}}
                    assert profile['allowed_branches']==['B2'] and source.records[TARGET]['permissions']=={}
                    assert notices==[('C1',TARGET)]
                else:assert row.active is None and company.requires_permission_review is (case=='initial')
    asyncio.run(run())

@pytest.mark.parametrize('case',['blocked','demoted','uid'])
def test_draft_read_and_save_do_not_trust_cached_root(case,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,_,_):
            install(source)
            if case=='blocked':source.patch(ACTOR,is_active=False)
            if case=='demoted':source.patch(ACTOR,role='employee')
            if case=='uid':source.patch(ACTOR,uid='replacement')
            assert (await client.get('/auth/companies/C1/permission-policy')).status_code==403
            response=await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':0,'configuration':CONFIG})
            assert response.status_code==403,response.text
    asyncio.run(run())


def test_new_company_invitation_real_uid_review_then_verified_activation(tmp_path,monkeypatch):
    from test_account_lifecycle import lifecycle_source
    from app.routes import auth
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,factory,_):
            lifecycle_source(source,monkeypatch)
            # Give review scans a synthetic query supporting all SDK calls.
            original=source.collection
            def collection(name):
                result=original(name)
                if name=='users':
                    def where(field,op,value):
                        class Query:
                            def limit(self,count):return self
                            def stream(self,transaction=None):
                                return [original('users').document(key).get(transaction=transaction) for key,item in source.records.items() if item.get(field)==value]
                        return Query()
                    result.where=where
                return result
            source.collection=collection
            async with factory() as db:
                company=await db.get(models.Company,'C1');company.requires_permission_review=True;await db.commit()
            email='new-admin@example.com'
            response=await client.post('/auth/admin/add-user',json={'email':email,'name':'New admin','company_code':'C1','role':'admin','branch_code':'B2'})
            assert response.status_code==200,response.text
            assert source.records[email]['uid']=='' and source.records[email]['permissions']=={}
            token={'uid':'actual-new-uid','email':email,'email_verified':False}
            monkeypatch.setattr(auth.admin_auth,'verify_id_token',lambda *args,**kwargs:token)
            async def auto(**kwargs):return None
            monkeypatch.setattr(auth,'_auto_create_employee_if_needed',auto)
            monkeypatch.setattr(auth,'AsyncSessionLocal',factory)
            response=await client.post('/auth/complete-registration',headers={'authorization':'Bearer fixture'},json={'uid':'actual-new-uid','email':email})
            assert response.status_code==200,response.text
            assert source.records[email]['status']=='pending'
            token['email_verified']=True
            assert (await client.post('/auth/verify-user',headers={'authorization':'Bearer fixture'})).status_code==403
            value=copy.deepcopy(CONFIG);value['admin_profiles']['actual-new-uid']=value['admin_profiles'].pop('target-uid')
            response=await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':0,'configuration':value})
            assert response.status_code==200,response.text
            review=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            assert review['accounts'][-1]['uid'] or review['accounts'][0]['uid']
            response=await client.post('/auth/companies/C1/permission-policy/activate',json={'expected_revision':1,'source_review_token':review['source_review_token'],'confirmed_review':True})
            assert response.status_code==200,response.text
            response=await client.post('/auth/verify-user',headers={'authorization':'Bearer fixture'})
            assert response.status_code==200,response.text
            assert source.records[email]['status']=='active'
            async with factory() as db:
                profile=await load_effective_policy_profile(db,{**source.records[email],'email':email},role='admin')
                assert profile['permissions']=={'المبيعات':{'إضافة':True}} and profile['delegable_branches']==['B2']
    asyncio.run(run())


def test_company_delete_cleans_policy_in_same_sql_commit_before_code_reuse(tmp_path,monkeypatch):
    from app.routes import auth
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,factory,_):
            install(source)
            class Query:
                def get(self):return []
            source.where=lambda *args:Query()
            async with factory() as db:
                db.add(models.CompanyPermissionPolicy(company_code='C1',revision=1,active_revision=1,
                    active=copy.deepcopy(CONFIG),draft=copy.deepcopy(CONFIG)));await db.commit()
            response=await client.delete('/auth/companies/delete/C1?admin_job_code=99')
            assert response.status_code==200,response.text
            async with factory() as db:
                assert await db.get(models.Company,'C1') is None
                assert await db.get(models.CompanyPermissionPolicy,'C1') is None
            response=await client.post('/auth/companies/add?admin_job_code=99',json={'code':'C1','name':'Reused code'})
            assert response.status_code==200,response.text
            async with factory() as db:
                assert (await db.get(models.Company,'C1')).requires_permission_review is True
                assert await db.get(models.CompanyPermissionPolicy,'C1') is None
    asyncio.run(run())

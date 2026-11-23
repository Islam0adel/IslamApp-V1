"""Invitation writes are atomic with review and use current authority."""
import asyncio
import copy
import pytest
from app.core import models
from test_permission_editor_integration import fixture, ACTOR, TARGET
from test_management_directory import grant
from test_account_lifecycle import lifecycle_source

NEW='invited@example.invalid'
@pytest.mark.parametrize('action',['add','approve'])
@pytest.mark.parametrize('case',['success','none','delegation','employee','blocked','race','phone-only','wrong-branch','foreign','admin-role','duplicate-email','duplicate-phone','duplicate-username'])
def test_invitation_creation(action,case,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            lifecycle_source(source,monkeypatch);await grant(factory,[action])
            data={'name':'New','phone_number':'01012345678','email':NEW,'role':'employee','branch_code':'B2','company_code':'C1','username':'new_name'}
            source.requests['r1'].update(email=NEW,phone_number='01012345678',name='New')
            expected=200
            if case=='none':await grant(factory,[]);expected=403
            if case=='delegation':await grant(factory,[],delegated=[action]);expected=403
            if case=='employee':source.patch(ACTOR,role='employee',permissions={'إدارة المستخدمين':{'إضافة' if action=='add' else 'الموافقة على طلب':True}})
            if case=='blocked':source.patch(ACTOR,is_active=False);expected=403
            if case=='race':source.before_lifecycle_commit=lambda:source.patch(ACTOR,is_active=False);expected=403
            if case=='phone-only':data['email']='';source.requests['r1']['email']='';expected=400
            if case=='wrong-branch':data['branch_code']='missing';expected=400
            if case=='foreign' and action=='approve':source.requests['r1']['company_code']='C2';expected=403
            if case=='admin-role':data['role']='admin';expected=403
            if case=='duplicate-email':source.records[TARGET]['email']=NEW;expected=409
            if case=='duplicate-phone':source.patch(TARGET,phone_number='01012345678');expected=409
            if case=='duplicate-username':
                source.patch(TARGET,username='new_name')
                if action=='add':expected=409
            # Active operating add does not imply branch delegation. Grant the
            # explicit branch separately, never infer it from the actor's scope.
            if case not in ('none','delegation'):
                async with factory() as db:
                    row=await db.get(models.CompanyPermissionPolicy,'C1');config=copy.deepcopy(row.active)
                    config['admin_profiles']['actor-uid']['delegable_branches']=['B2'];row.active=config;await db.commit()
            if action=='add':response=await client.post('/auth/admin/add-user',json=data)
            else:response=await client.post('/auth/admin/registration-requests/r1/approve',json=data)
            if case=='employee':expected=403 # Employee has no independent branch delegation.
            assert response.status_code==expected,response.text
            if expected==200:
                value=source.records[NEW]
                assert value['uid']=='' and value['status']=='pending' and value['invitation_email']==NEW
                assert value['permissions']=={} and value['allowed_branches']==['B2']
                assert 'requires_signup_approval' not in value
                if action=='approve':assert source.requests['r1']['status']=='approved'
            else:
                assert NEW not in source.records
                assert source.requests['r1']['status']=='pending'
    asyncio.run(run())

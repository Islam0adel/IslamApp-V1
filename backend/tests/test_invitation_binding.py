"""Actual completion and email verification with SQL and synthetic providers."""
import asyncio
import copy
import pytest
from app.routes import auth
from app.core import models, auth_middleware as middleware
from test_permission_editor_integration import fixture, TARGET as OLD_TARGET
TARGET='target@example.com'
from test_account_lifecycle import lifecycle_source

@pytest.mark.parametrize('case',['success','phone-only','wrong-email','uid-conflict','blocked','race','unverified','wrong-token-uid'])
def test_invitation_binding_and_verified_email_gate(case,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            source.records[TARGET]=source.records.pop(OLD_TARGET)
            source.versions[TARGET]=1
            lifecycle_source(source,monkeypatch)
            source.records[TARGET].update(uid='',email=TARGET,invitation_email=TARGET,status='pending',phone_number='01012345678',permissions={'المبيعات':{'معاينة':True}})
            token={'uid':'real-uid','email':TARGET,'email_verified':False}
            monkeypatch.setattr(auth.admin_auth,'verify_id_token',lambda *a,**k:copy.deepcopy(token))
            async def auto(**kwargs):return None
            monkeypatch.setattr(auth,'_auto_create_employee_if_needed',auto)
            monkeypatch.setattr(auth,'AsyncSessionLocal',factory)
            original_pending=auth.find_pending_user
            monkeypatch.setattr(auth,'find_pending_user',lambda **kwargs:source.collection('users').document(TARGET).get())
            expected=200
            if case=='phone-only':source.records[TARGET].update(email='',invitation_email='');expected=409
            if case=='wrong-email':source.records[TARGET]['invitation_email']='other@example.invalid';expected=403
            if case=='uid-conflict':source.records[TARGET]['uid']='other-uid';expected=409
            if case=='blocked':source.records[TARGET]['is_active']=False;expected=403
            if case=='race':source.before_lifecycle_commit=lambda:source.patch(TARGET,is_active=False);expected=403
            if case=='wrong-token-uid':token['uid']='other-uid';expected=403
            payload={'email':TARGET,'uid':'real-uid','phone_number':'01012345678'}
            response=await client.post('/auth/complete-registration',json=payload,headers={'authorization':'Bearer synthetic'})
            assert response.status_code==expected,response.text
            if expected!=200:return
            value=source.records[TARGET]
            assert value['uid']=='real-uid' and value['status']=='pending'
            assert value['permissions']=={'المبيعات':{'معاينة':True}} and value['allowed_branches']==['B2']
            response=await client.post('/auth/verify-user',headers={'authorization':'Bearer synthetic'})
            assert response.status_code==403 and source.records[TARGET]['status']=='pending'
            token['email_verified']=True
            response=await client.post('/auth/verify-user',headers={'authorization':'Bearer synthetic'})
            assert response.status_code==200,response.text
            assert source.records[TARGET]['status']=='active' and source.records[TARGET]['email_verified'] is True
            # No synthetic UID was added to company admin assignments.
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1')
                assert 'real-uid' not in row.active['admin_profiles']
    asyncio.run(run())


def test_old_phone_only_invitation_can_receive_email_then_bind(tmp_path,monkeypatch):
    from test_management_directory import grant
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            # Metadata fixture supplies real update_time; add email here before
            # switching to the lifecycle transaction transport.
            await grant(factory,['edit']);source.patch(OLD_TARGET,uid='',status='pending')
            class Query:
                def __init__(self,field,value):self.field,self.value=field,value
                def limit(self,count):return self
                def stream(self,transaction=None):
                    return [source.document(key).get(transaction=transaction) for key,value in source.records.items() if value.get(self.field)==self.value]
            source.where=lambda field,op,value:Query(field,value)

            editor=await client.get('/auth/user-editor/'+OLD_TARGET);assert editor.status_code==200
            value=editor.json()
            assert value['can_set_invitation_email'] is True
            # Existing document id is a picker identity, not invitation email.
            response=await client.put('/auth/admin/edit-user',json={'email':OLD_TARGET,'invitation_email':'invite@example.invalid',
                'expected_target_uid':'','expected_profile_version':value['profile_version'],'expected_policy_revision':1})
            assert response.status_code==200,response.text
            assert source.records[OLD_TARGET]['invitation_email']=='invite@example.invalid'
    asyncio.run(run())


@pytest.mark.parametrize('case',['success','auth-failure','verified','active','wrong-uid'])
def test_self_cancel_preserves_invitation_email_and_never_lies(case,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            lifecycle_source(source,monkeypatch)
            source.records[OLD_TARGET].update(email=OLD_TARGET,status='pending',email_verified=False)
            token={'uid':'target-uid','email':OLD_TARGET,'email_verified':False}
            monkeypatch.setattr(auth.admin_auth,'verify_id_token',lambda *a,**k:token)
            if case=='auth-failure':
                def fail(uid):raise RuntimeError('synthetic failure')
                monkeypatch.setattr(auth.admin_auth,'delete_user',fail)
            if case=='verified':token['email_verified']=True
            if case=='active':source.records[OLD_TARGET]['status']='active'
            if case=='wrong-uid':token['uid']='different-uid'
            response=await client.post('/auth/cancel-registration',headers={'authorization':'Bearer synthetic'})
            expected=200 if case=='success' else (503 if case=='auth-failure' else 403)
            assert response.status_code==expected,response.text
            value=source.records[OLD_TARGET]
            assert value['email']==OLD_TARGET
            if case=='success':assert value['uid']=='' and value['status']=='pending' and value['is_active']
            if case=='auth-failure':assert value['uid']=='target-uid' and value['is_active'] is False and value['account_lifecycle']['action']=='cancel'
    asyncio.run(run())

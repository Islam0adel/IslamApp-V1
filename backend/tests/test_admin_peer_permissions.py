"""Role-target regression: real HTTP and SQL, synthetic versioned source."""
import asyncio
import copy
import pytest
from app.core import models
from test_permission_editor_integration import fixture, ACTOR, TARGET, VIEW, ALL
from test_management_directory import install
from test_account_editor import grant, EDIT

async def read_payload(client,email):
    response=await client.get('/auth/permission-editor/'+email)
    assert response.status_code==200,response.text
    value=response.json()
    return value,{'email':email,'permissions':copy.deepcopy(value['permissions']),
        'expected_target_uid':value['uid'],'expected_profile_version':value['profile_version'],
        'expected_policy_revision':value['company_policy_revision']}

@pytest.mark.parametrize('target',['peer','self'])
def test_admin_operating_save_is_authoritative_and_never_expands_delegation(target,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,branches=['all']) as (client,source,factory,_):
            install(source)
            source.patch(TARGET,role='admin',permissions={'legacy':{'unused':True}})
            email=ACTOR if target=='self' else TARGET
            before=copy.deepcopy(source.records[email]['permissions'])
            value,payload=await read_payload(client,email)
            assert value['permissions']=={}
            payload['permissions']=copy.deepcopy(VIEW)
            response=await client.post('/auth/update-permissions',json=payload)
            assert response.status_code==200,response.text
            assert source.records[email]['permissions']==before
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1')
                entry=row.active['admin_profiles'][source.records[email]['uid']]
                assert entry['operating_permissions']==VIEW
                assert entry['delegable_permissions']==(VIEW if target=='self' else {})
                assert row.active_revision==2 and row.revision==2
            fresh,denied=await read_payload(client,email)
            assert fresh['permissions']==VIEW
            denied['permissions']={'المبيعات':{'حذف':True}}
            assert (await client.post('/auth/update-permissions',json=denied)).status_code==403
    asyncio.run(run())


def test_root_all_roles_access_and_root_bypass_stored_flags(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,factory,_):
            install(source);source.patch(TARGET,role='admin')
            value,payload=await read_payload(client,ACTOR)
            payload['permissions']={'خارج سقف الشركة':{'علامة محفوظة':True}}
            assert (await client.post('/auth/update-permissions',json=payload)).status_code==200
            assert source.records[ACTOR]['role']=='super_admin'
            assert (await client.get('/auth/user-editor/'+ACTOR)).status_code==200
            assert (await client.get('/auth/permission-editor/'+TARGET)).status_code==200
    asyncio.run(run())


def test_admin_directory_and_metadata_include_peers_not_root_or_foreign(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            install(source);await grant(factory,[EDIT]);source.patch(TARGET,role='admin')
            source.records['root@example.invalid']={'uid':'root','company_code':'C1','role':'super_admin'}
            source.records['foreign@example.invalid']={'uid':'foreign','company_code':'C2','role':'admin'}
            for route in ('permission-editor-targets','user-management-directory'):
                response=await client.get('/auth/'+route)
                assert response.status_code==200,response.text
                assert {v['email'] for v in response.json()['users']}=={ACTOR,TARGET}
            response=await client.get('/auth/user-editor/'+TARGET)
            assert response.status_code==200,response.text
            value=response.json()
            payload={'email':TARGET,'name':'Peer renamed','expected_target_uid':value['uid'],
                'expected_profile_version':value['profile_version'],'expected_policy_revision':value['company_policy_revision']}
            assert (await client.put('/auth/admin/edit-user',json=payload)).status_code==200
            assert source.records[TARGET]['name']=='Peer renamed' and source.records[TARGET]['role']=='admin'
            assert (await client.get('/auth/user-editor/root@example.invalid')).status_code==403
    asyncio.run(run())


def test_direct_admin_edit_retains_draft_and_requires_visible_reconciliation(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True) as (client,source,factory,_):
            install(source);source.patch(TARGET,role='admin')
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1');saved=copy.deepcopy(row.active)
                saved['admin_profiles']['target-uid']={'operating_permissions':{},'delegable_permissions':{},'delegable_branches':[]}
                row.draft=copy.deepcopy(saved);row.draft_base_active_revision=1;await db.commit()
            _,payload=await read_payload(client,TARGET);payload['permissions']=VIEW
            assert (await client.post('/auth/update-permissions',json=payload)).status_code==200
            review=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            assert review['draft']==saved and review['draft_requires_reconciliation'] is True
            activation={'expected_revision':review['revision'],'source_review_token':review['source_review_token'],'confirmed_review':True}
            assert (await client.post('/auth/companies/C1/permission-policy/activate',json=activation)).status_code==409
            draft={'expected_revision':review['revision'],'configuration':saved}
            assert (await client.put('/auth/companies/C1/permission-policy/draft',json=draft)).status_code==409
            draft['reconciled_active_revision']=1
            assert (await client.put('/auth/companies/C1/permission-policy/draft',json=draft)).status_code==409
            draft['reconciled_active_revision']=review['active_revision']
            accepted=await client.put('/auth/companies/C1/permission-policy/draft',json=draft)
            assert accepted.status_code==200,accepted.text
            assert accepted.json()['draft_requires_reconciliation'] is False
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1')
                assert row.active['admin_profiles']['target-uid']['operating_permissions']==VIEW
    asyncio.run(run())

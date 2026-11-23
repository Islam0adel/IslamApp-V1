"""Legacy permission-editor status control uses current authority and CAS."""
import asyncio
import pytest
from test_permission_editor_integration import fixture,ACTOR,TARGET

@pytest.mark.parametrize('case,expected',[
    ('employee',200),('employee-no-grant',403),('employee-admin-target',403),
    ('admin',200),('foreign',404),('root-target',403),('blocked',403),
    ('actor-uid',403),('stale-version',409),('stale-uid',409),('held',409),
    ('active-policy',403),('root-self',403),('unchanged',200),
])
def test_status_authority_and_cas(tmp_path,monkeypatch,case,expected):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=case=='root-self',active=case=='active-policy') as (client,source,_,notices):
            target=ACTOR if case=='root-self' else TARGET
            if case.startswith('employee'):
                source.patch(ACTOR,role='employee',permissions={'صلاحيات عامة':{'صفحة الصلاحيات(الاعدادات)':case!='employee-no-grant'}})
            if case=='employee-admin-target':source.patch(TARGET,role='admin')
            if case=='foreign':source.patch(TARGET,company_code='C2')
            if case=='root-target':source.patch(TARGET,role='super_admin')
            if case=='blocked':source.patch(ACTOR,is_active=False)
            if case=='actor-uid':source.patch(ACTOR,uid='replacement')
            if case=='held':source.patch(TARGET,account_lifecycle={'action':'delete'})
            from test_permission_editor_integration import Snapshot
            payload={'email':target,'is_active':case=='unchanged','expected_target_uid':source.records[target]['uid'],
                'expected_profile_version':Snapshot(source,target).update_time.isoformat()}
            if case=='stale-version':payload['expected_profile_version']='stale'
            if case=='stale-uid':payload['expected_target_uid']='stale'
            response=await client.post('/auth/permission-editor-status',json=payload)
            assert response.status_code==expected,response.text
            if expected==200:
                assert source.records[target]['is_active']==payload['is_active']
                assert response.json()['changed']==(case!='unchanged')
                assert len(notices)==(0 if case=='unchanged' else 1)
            else:assert source.commits==0 and not notices
    asyncio.run(run())

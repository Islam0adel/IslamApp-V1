"""Current company directory consumers, real SQL and synthetic source scans."""
import asyncio
import copy
import pytest
from app.core import models
from app.core.account_management import ACTIONS
from test_permission_editor_integration import fixture, ACTOR, TARGET, Snapshot

CATEGORY='إدارة المستخدمين'

def install(source):
    source.scans=[];source.during_scan=None
    class Query:
        def __init__(self,company):self.company=company
        def stream(self):
            source.scans.append(self.company)
            for key,value in list(source.records.items()):
                if self.company is None or value.get('company_code')==self.company:
                    yield Snapshot(source,key)
                    if source.during_scan is not None:
                        hook=source.during_scan;source.during_scan=None;hook()
    def where(field,op,value):
        assert field=='company_code' and op=='=='
        return Query(value)
    source.where=where;source.stream=lambda:Query(None).stream()

async def grant(factory,rights,delegated=None):
    async with factory() as db:
        row=await db.get(models.CompanyPermissionPolicy,'C1');value=copy.deepcopy(row.active)
        value['company_permissions'][CATEGORY]={action:True for action in ACTIONS.values()}
        profile=value['admin_profiles']['actor-uid']
        profile['operating_permissions']={CATEGORY:{ACTIONS[key]:True for key in rights}}
        profile['delegable_permissions']={CATEGORY:{ACTIONS[key]:True for key in (delegated or [])}}
        row.active=value;await db.commit()

@pytest.mark.parametrize('right',['view','edit','status','add','approve','delete','reset'])
def test_directory_uses_operating_actions_and_minimal_target_picker(tmp_path,monkeypatch,right):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            install(source);await grant(factory,[right])
            source.patch(TARGET,phone_number='01000000000',username='private_name',salary=9000,hr_viewable_employees=['E1'])
            response=await client.get('/auth/user-management-directory?company_code=C2')
            assert response.status_code==200,response.text
            value=response.json();assert value['company_code']=='C1' and value['actions'][right]
            if right=='edit':assert value['actions']['add'] and not value['actions']['view']
            if right in ('add','approve'):
                assert value['users']==[] and not source.scans
            else:
                assert source.scans==['C1'] and len(value['users'])==2
                row=next(v for v in value['users'] if v['email']==TARGET);assert row['email']==TARGET
                assert 'salary' not in row and 'permissions' not in row and 'hr_viewable_employees' not in row
                if right=='view':assert row['phone_number']=='01000000000' and row['username']=='private_name'
                else:
                    assert row['directory_summary_only'] is True
                    assert 'phone_number' not in row and 'username' not in row and 'allowed_branches' not in row
            compat=await client.get('/auth/company-users?company_code=C2')
            assert compat.status_code==200 and compat.json()==value['users']
    asyncio.run(run())

@pytest.mark.parametrize('case',['none','delegation-only','raw-source','blocked','uid','company','query-failure','changed-during-scan'])
def test_directory_refuses_stale_or_unavailable_authority(tmp_path,monkeypatch,case):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            install(source);await grant(factory,['view'])
            expected=403
            if case=='none':await grant(factory,[])
            if case=='delegation-only':await grant(factory,[],delegated=['view','edit'])
            if case=='raw-source':
                await grant(factory,[]);source.patch(ACTOR,permissions={CATEGORY:{'معاينة':True}})
            if case=='blocked':source.patch(ACTOR,is_active=False)
            if case=='uid':source.patch(ACTOR,uid='new-owner')
            if case=='company':source.patch(ACTOR,company_code='C2');expected=404
            if case=='query-failure':
                def fail(*args):raise RuntimeError('synthetic query failure')
                source.where=fail;expected=503
            if case=='changed-during-scan':source.during_scan=lambda:source.patch(ACTOR,status='suspended')
            response=await client.get('/auth/company-users?company_code=C1')
            assert response.status_code==expected,response.text
            assert 'private_name' not in response.text
            if case in ('none','delegation-only','raw-source','blocked','uid','company'):assert not source.scans
    asyncio.run(run())

@pytest.mark.parametrize('root',[False,True])
def test_legacy_directory_keeps_existing_role_and_detail_behavior(tmp_path,monkeypatch,root):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=root,active=False) as (client,source,_,_):
            install(source);source.patch(TARGET,username='legacy',phone_number='01000000000')
            response=await client.get('/auth/company-users'+('' if root else '?company_code=C2'))
            assert response.status_code==200,response.text
            row=next(row for row in response.json() if row['email']==TARGET)
            assert row['username']=='legacy' and row['phone_number']=='01000000000'
            assert row['allowed_branches']==['B2'] and row['startup_branch_code']=='B2'
            assert source.scans==[None if root else 'C1']
    asyncio.run(run())

@pytest.mark.parametrize('right',['approve','reject','view','edit',None])
def test_actual_request_list_requires_review_action_and_company_clamp(tmp_path,monkeypatch,right):
    from types import SimpleNamespace
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            await grant(factory,[] if right is None else [right]);original=source.collection;scans=[]
            requests={'r1':{'name':'Pending one','company_code':'C1','status':'pending','phone_number':'01000000000'},
                'foreign':{'name':'Foreign secret','company_code':'C2','status':'pending'}}
            class Query:
                def __init__(self,filters=()):self.filters=filters
                def where(self,key,op,value):assert op=='==';return Query((*self.filters,(key,value)))
                def stream(self):
                    scans.append(self.filters)
                    return [SimpleNamespace(id=key,to_dict=lambda value=value:copy.deepcopy(value)) for key,value in requests.items()
                        if all(value.get(field)==expected for field,expected in self.filters)]
            source.collection=lambda name:Query() if name=='registration_requests' else original(name)
            response=await client.get('/auth/admin/registration-requests?status=pending')
            if right not in ('approve','reject'):
                assert response.status_code==403 and not scans,response.text
            else:
                assert response.status_code==200,response.text
                assert [row['id'] for row in response.json()]==['r1'] and 'Foreign secret' not in response.text
                assert scans==[(('company_code','C1'),('status','pending'))]
    asyncio.run(run())

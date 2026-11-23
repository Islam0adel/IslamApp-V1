"""Positive scope changes and the real installed source transaction decorator."""
import asyncio
import copy
import pytest
from google.api_core.exceptions import Aborted
from app.core import models, permission_editor as editor
from app.routes import auth
from test_permission_editor_integration import fixture, load, ACTOR, TARGET, VIEW, ALL, Transaction, Reference, Snapshot


def test_branch_expansion_carries_only_delegated_rights_and_preserves_explicit_own_hr(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,branches=['B2','B3']) as (client,source,factory,_):
            source.patch(TARGET,permissions={**copy.deepcopy(VIEW),'الموارد البشرية':{'canViewOwnHRData':True}})
            _,data=await load(client); data['allowed_branches']=['B2','B3']
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==200,response.text
            assert source.records[TARGET]['allowed_branches']==['B2','B3']
            assert source.records[TARGET]['permissions']['الموارد البشرية']['canViewOwnHRData'] is True
            async with factory() as db:
                employee=await db.get(models.Employee,1)
                assert employee.branch_code=='B1' and employee.user_uid=='target-uid'
    asyncio.run(run())


def test_delegated_hr_filter_changes_do_not_require_operating_hr_data_access(tmp_path,monkeypatch):
    async def run():
        delegation={'الموارد البشرية':{'canViewEmployees':True}}
        async with fixture(tmp_path,monkeypatch,delegation=delegation) as (client,source,_,_):
            source.patch(TARGET,permissions=delegation,hr_viewable_employees=['E1'])
            _,data=await load(client); data['hr_viewable_employees']=['E2']
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==200,response.text
            assert source.records[TARGET]['hr_viewable_employees']==['E2']
            assert source.records[ACTOR]['permissions']=={} and source.records[ACTOR]['allowed_branches']==['B1']
    asyncio.run(run())


def test_sql_policy_change_after_editor_load_rejects_the_old_submit(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            _,data=await load(client); data['permissions']=VIEW
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1')
                row.active_revision=2; row.active={'company_permissions':{},'admin_profiles':{}}
                await db.commit()
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==409 and source.records[TARGET]['permissions']=={} and source.commits==0
    asyncio.run(run())

@pytest.mark.parametrize('field,value',[('expected_policy_revision',True),('allowed_branches',[1]),
    ('clear_hr_viewable_employees','true'),('expected_profile_version',1)])
def test_editor_contract_does_not_coerce_security_fields(field,value,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,_):
            _,data=await load(client); data[field]=value
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==422 and source.commits==0
    asyncio.run(run())


class SDKTransaction(Transaction):
    """Synthetic transport implementing the installed decorator's contract."""
    _read_only=False; _max_attempts=5
    def __init__(self,source): super().__init__(source); self._id=b'fixture-transaction'
    def _clean_up(self): self.reads={}; self.writes=[]
    def _begin(self,retry_id=None): self._id=b'fixture-transaction'; self.source.attempts+=1
    def _commit(self):
        if self.source.before_commit is not None:
            hook=self.source.before_commit; self.source.before_commit=None; hook()
        if any(self.source.versions.get(email,0)!=version for email,version in self.reads.items()):
            raise Aborted('synthetic source version changed')
        for email,values in self.writes:
            if email not in self.source.records:self.source.records[email]={};self.source.versions[email]=0
            self.source.records[email].update(copy.deepcopy(values));self.source.versions[email]+=1
        self.source.commits+=1
    def set(self,ref,values,**kwargs):self.writes.append((ref.email,copy.deepcopy(values)))
    def _rollback(self): self.writes=[]

@pytest.mark.parametrize('race',[False,True])
def test_production_runner_uses_installed_sdk_retry_and_callback_revalidation(race,tmp_path,monkeypatch):
    original_runner=editor.run_source_transaction
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,notices):
            monkeypatch.setattr(editor,'run_source_transaction',original_runner)
            source.transaction=lambda:SDKTransaction(source)
            # SDK retry transport now covers clock/marker docs in same commit.
            original_collection=source.collection
            class Collection:
                def __init__(self,name):self.name=name
                def document(self,key):return Reference(source,self.name+'/'+key)
            source.collection=lambda name:original_collection(name) if name=='users' else Collection(name)
            monkeypatch.setattr(Reference,'path',property(lambda ref:ref.email if '/' in ref.email else 'users/'+ref.email),raising=False)

            _,data=await load(client); data['permissions']=VIEW
            if race: source.before_commit=lambda:source.patch(ACTOR,is_active=False)
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==(403 if race else 200),response.text
            assert source.attempts==(2 if race else 1)
            assert source.commits==(0 if race else 1)
            assert len(notices)==(0 if race else 1)
    asyncio.run(run())


def test_missing_sql_dependency_never_falls_back_to_source_only_permission_writes(monkeypatch):
    from types import SimpleNamespace
    from fastapi import HTTPException
    class UnusableSource:
        def collection(self,*args): raise AssertionError('unverified source write path reached')
    monkeypatch.setattr(auth,'db',UnusableSource())
    async def run():
        with pytest.raises(HTTPException) as error:
            await auth.update_user_permissions(auth.PermissionsUpdateModel(email=TARGET,permissions={}),
                SimpleNamespace(state=SimpleNamespace(auth_user={'role':'super_admin'})))
        assert error.value.status_code==503
    asyncio.run(run())


def test_source_failure_is_not_acknowledged_or_exposed_as_internal_error(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,notices):
            _,data=await load(client); data['permissions']=VIEW
            def unavailable(*args): raise RuntimeError('private transport diagnostics')
            monkeypatch.setattr(editor,'run_source_transaction',unavailable)
            response=await client.post('/auth/update-permissions',json=data)
            assert response.status_code==503 and 'private transport' not in response.text
            assert source.commits==0 and not notices
    asyncio.run(run())


@pytest.mark.parametrize('method',['GET','POST'])
def test_active_admin_with_no_delegation_has_no_editor_authority(method,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,delegation={},branches=[]) as (client,source,_,notices):
            source.patch(ACTOR,delegable_permissions=ALL,delegable_branches=['all'])
            if method=='GET': response=await client.get('/auth/permission-editor/'+TARGET)
            else: response=await client.post('/auth/update-permissions',json={
                'email':TARGET,'permissions':{},'expected_target_uid':'target-uid',
                'expected_profile_version':'stale','expected_policy_revision':1})
            assert response.status_code==403
            assert source.commits==0 and not notices
    asyncio.run(run())


def test_editor_lookups_use_delegation_not_operating_data_and_expose_only_labels(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,_,_):
            profile,_=await load(client)
            assert profile['branch_choices']==[{'code':'B2','name':'B2'}]
            assert profile['employee_choices']==[]
            assert source.records[ACTOR]['allowed_branches']==['B1']
            assert 'salary' not in str(profile) and 'another-private-admin' not in str(profile)
    asyncio.run(run())


def test_hr_editor_lookups_are_small_company_scoped_labels_not_salary_records(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,delegation={'الموارد البشرية':{'canViewEmployees':True}}) as (client,source,factory,_):
            async with factory() as db:
                db.add(models.Employee(company_code='C1',code='E3',name='Outside delegated scope',branch_code='B3'))
                await db.commit()
            profile,_=await load(client)
            choices=profile['employee_choices']
            assert {v['code'] for v in choices}=={'E1','E2'}
            assert all(set(v)=={'code','name'} for v in choices)
    asyncio.run(run())


@pytest.mark.parametrize('revision',[None,0,-1])
def test_editor_rejects_active_policy_without_a_valid_revision(revision,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1');row.active_revision=revision;await db.commit()
            response=await client.get('/auth/permission-editor/'+TARGET)
            assert response.status_code==503 and source.commits==0
    asyncio.run(run())

"""Real route/SQL boundaries, versioned synthetic Firestore and Auth transport."""
import asyncio
import copy
from types import SimpleNamespace
import pytest
from google.cloud import firestore
from sqlalchemy import select
from app.core import models, permission_editor
from app.routes import auth
from test_permission_editor_integration import fixture, ACTOR, TARGET
from test_management_directory import grant


def lifecycle_source(source, monkeypatch):
    original_collection = source.collection
    requests = {'r1': {'company_code': 'C1', 'status': 'pending', 'name': 'Request'}}
    source.requests = requests
    class Ref:
        def __init__(self, name, key): self.name, self.key = name, key
        def get(self, transaction=None):
            storage = source.records if self.name == 'users' else requests
            if transaction is not None: transaction.reads[(self.name, self.key)] = copy.deepcopy(storage.get(self.key))
            return SimpleNamespace(id=self.key, exists=self.key in storage, to_dict=lambda: copy.deepcopy(storage.get(self.key)))
    class Query:
        def __init__(self, name, field, value): self.name,self.field,self.value=name,field,value
        def limit(self, count): return self
        def stream(self, transaction=None):
            storage=source.records if self.name=='users' else requests
            for key,value in list(storage.items()):
                if value.get(self.field)==self.value:
                    yield Ref(self.name,key).get(transaction=transaction)
    class Collection:
        def __init__(self, name): self.name = name
        def document(self, key): return Ref(self.name, key)
        def where(self, field, op, value):
            assert op=='=='
            return Query(self.name,field,value)
    source.collection = lambda name: Collection(name)
    source.before_lifecycle_commit = None
    def run(source, callback):
        for _ in range(5):
            tx = SimpleNamespace(reads={}, writes=[])
            tx.update = lambda ref, values: tx.writes.append(('update', ref, copy.deepcopy(values)))
            tx.set = lambda ref, values: tx.writes.append(('set',ref,copy.deepcopy(values)))
            tx.delete = lambda ref: tx.writes.append(('delete', ref, None))
            result = callback(tx)
            if source.before_lifecycle_commit:
                hook = source.before_lifecycle_commit; source.before_lifecycle_commit = None; hook()
            if any((source.records if name == 'users' else requests).get(key) != value for (name,key),value in tx.reads.items()): continue
            for action, ref, value in tx.writes:
                storage = source.records if ref.name == 'users' else requests
                if action == 'delete': storage.pop(ref.key)
                else:
                    if action=='set': storage[ref.key]={}
                    for key, item in value.items():
                        if item == firestore.DELETE_FIELD: storage[ref.key].pop(key, None)
                        else: storage[ref.key][key] = item
            source.commits += 1
            return result
        raise RuntimeError('retry limit')
    monkeypatch.setattr(permission_editor, 'run_source_transaction', run)
    deleted = []
    monkeypatch.setattr(auth.admin_auth, 'get_user', lambda uid: SimpleNamespace(uid=uid, email=TARGET))
    monkeypatch.setattr(auth.admin_auth, 'delete_user', lambda uid: deleted.append(uid))
    return deleted


@pytest.mark.parametrize('action', ['delete', 'reset', 'reject'])
@pytest.mark.parametrize('case', ['success', 'none', 'delegation', 'actor-blocked', 'actor-uid', 'target-admin', 'foreign', 'race'])
def test_current_lifecycle_authority(action, case, tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            deleted = lifecycle_source(source,monkeypatch)
            await grant(factory,[action])
            expected=200
            if case=='none': await grant(factory,[]); expected=403
            if case=='delegation': await grant(factory,[],delegated=[action]); expected=403
            if case=='actor-blocked': source.patch(ACTOR,is_active=False); expected=403
            if case=='actor-uid': source.patch(ACTOR,uid='replacement'); expected=403
            if case=='target-admin' and action!='reject': source.patch(TARGET,role='admin'); expected=403
            if case=='foreign':
                if action=='reject': source.requests['r1']['company_code']='C2'; expected=403
                else: source.patch(TARGET,company_code='C2'); expected=404
            if case=='race':
                source.before_lifecycle_commit=lambda:source.patch(ACTOR,is_active=False); expected=403
            if action=='reject': response=await client.post('/auth/admin/registration-requests/r1/reject')
            elif action=='reset': response=await client.post('/auth/admin/reset-pending-user',params={'email':TARGET})
            else: response=await client.delete('/auth/admin/delete-user',params={'email':TARGET})
            assert response.status_code==expected,response.text
            if expected!=200:
                assert not deleted and 'account_lifecycle' not in source.records[TARGET]
            elif action=='reject':
                assert source.requests['r1']['status']=='rejected' and not deleted
            elif action=='delete':
                assert TARGET not in source.records and deleted==['target-uid']
            else:
                value=source.records[TARGET]
                assert value['uid']=='' and value['status']=='pending' and value['email']==TARGET
                assert value['is_active'] and 'account_lifecycle' not in value
                assert value['allowed_branches']==['B2']
            if expected==200 and action!='reject':
                async with factory() as db:
                    employee=await db.scalar(select(models.Employee).where(models.Employee.code=='E1'))
                    assert employee.user_uid==''
    asyncio.run(run())


@pytest.mark.parametrize('action',['delete','reset'])
@pytest.mark.parametrize('failure',['auth','identity','source-finalize','not-found'])
def test_partial_failure_is_held_and_retryable(action,failure,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,notices):
            deleted=lifecycle_source(source,monkeypatch);await grant(factory,[action])
            def fail(uid):raise RuntimeError('synthetic transport failure')
            def missing(uid):raise auth.admin_auth.UserNotFoundError('synthetic missing identity')
            if failure=='auth':monkeypatch.setattr(auth.admin_auth,'delete_user',fail)
            if failure=='identity':monkeypatch.setattr(auth.admin_auth,'get_user',lambda uid:SimpleNamespace(uid=uid,email='different@example.invalid'))
            if failure=='source-finalize':
                runner=permission_editor.run_source_transaction
                def interrupted(src,callback):
                    if source.commits==1:raise RuntimeError('synthetic finalize failure')
                    return runner(src,callback)
                monkeypatch.setattr(permission_editor,'run_source_transaction',interrupted)
            if failure=='not-found':monkeypatch.setattr(auth.admin_auth,'get_user',missing)
            async def send():
                if action=='delete':return await client.delete('/auth/admin/delete-user',params={'email':TARGET})
                return await client.post('/auth/admin/reset-pending-user',params={'email':TARGET})
            response=await send()
            if failure=='not-found':assert response.status_code==200,response.text;return
            assert response.status_code==(409 if failure=='identity' else 503),response.text
            assert source.records[TARGET]['is_active'] is False
            assert source.records[TARGET]['account_lifecycle']['uid']=='target-uid'
            # A status edit must not reactivate a partial destructive action.
            editor=await client.get('/auth/user-editor/'+TARGET)
            assert editor.status_code in (403,409),editor.text
            monkeypatch.setattr(auth.admin_auth,'get_user',lambda uid:SimpleNamespace(uid=uid,email=TARGET))
            monkeypatch.setattr(auth.admin_auth,'delete_user',lambda uid:deleted.append(uid))
            if failure=='source-finalize':monkeypatch.setattr(permission_editor,'run_source_transaction',runner)
            response=await send();assert response.status_code==200,response.text
    asyncio.run(run())


@pytest.mark.parametrize('status',['approved','rejected'])
def test_request_rejection_does_not_overwrite_approval(status,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (client,source,factory,_):
            lifecycle_source(source,monkeypatch);await grant(factory,['reject'])
            source.requests['r1']['status']=status
            response=await client.post('/auth/admin/registration-requests/r1/reject')
            assert response.status_code==(409 if status=='approved' else 200)
            assert source.requests['r1']['status']==status
    asyncio.run(run())

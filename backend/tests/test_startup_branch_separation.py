"""Actual metadata HTTP editor preserves startup, operating and HR work branches."""
import asyncio
import copy
import pytest
from app.core import models
from test_permission_editor_integration import fixture, TARGET

@pytest.mark.parametrize('value,scope,expected,error', [
    ('B2',['B1','B2'],'B2',None), ('all',['B1','B2'],'',None),
    ('',['B1','B2'],'',None), (None,['B1','B2'],'B1',None),
    ('B3',['B1','B2'],None,400), ('FX',['B1','FX'],None,400),
    ('missing',['missing'],None,400), ('B2',None,'B2',None),
    ('B2',[],'B2',None), ('B2',{},None,409),
])
def test_startup_edit_preserves_access_scope_and_linked_work_branch(value,scope,expected,error,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,factory,_):
            source.patch(TARGET,branch_code='B1',allowed_branches=copy.deepcopy(scope))
            before=copy.deepcopy(source.records[TARGET])
            async with factory() as db:
                db.add(models.Branch(company_code='C2',code='FX',name='Foreign'));await db.commit()
            payload={'email':TARGET,'name':'Renamed'}
            if value is not None:payload['branch_code']=value
            response=await client.put('/auth/admin/edit-user',json=payload)
            assert response.status_code==(error or 200),response.text
            state=source.records[TARGET]
            if error:assert state==before
            else:
                assert state['branch_code']==expected
                assert state['allowed_branches']==scope and state['permissions']==before['permissions']
                assert 'allowed_branches' not in response.json()['updates']
                if value is None:assert 'branch_code' not in response.json()['updates']
            async with factory() as db:
                employee=await db.get(models.Employee,1)
                assert employee.branch_code=='B1' and employee.user_uid==state['uid']
    asyncio.run(run())

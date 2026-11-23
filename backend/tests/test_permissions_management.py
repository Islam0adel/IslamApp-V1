"""Legacy management scope through actual HTTP/SQL and fresh source records."""
import asyncio
import copy
import pytest
from app.core import models
from test_permission_editor_integration import fixture, ACTOR, TARGET

@pytest.mark.parametrize('actor_role,delegated,target_company,target_role,expected',[
    ('employee',False,'C1','employee',403),
    ('employee',True,'C1','employee',200),
    ('employee',True,'C2','employee',404),
    ('employee',True,'C1','admin',403),
    ('employee',True,'C1','super_admin',403),
    ('admin',False,'C2','employee',404),
    ('admin',False,'C1','admin',200),
    ('admin',False,'C1','super_admin',403),
    ('admin',False,'C1','employee',200),
    ('super_admin',False,'C2','employee',200),
    ('super_admin',False,'C2','admin',200),
    ('super_admin',False,'C2','super_admin',200),
    ('employee',True,'','employee',404),
])
def test_management_scope(actor_role,delegated,target_company,target_role,expected,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=actor_role=='super_admin',active=False) as (client,source,factory,notices):
            async with factory() as db:
                db.add(models.Company(code='C2',name='Second',is_active=True)); await db.commit()
            source.patch(ACTOR,role=actor_role,permissions={'صلاحيات عامة':{'صفحة الصلاحيات(الاعدادات)':delegated}})
            source.patch(TARGET,company_code=target_company,role=target_role)
            before=copy.deepcopy(source.records[TARGET])
            permissions={'المبيعات':{'إضافة':True}}
            response=await client.post('/auth/update-permissions',json={
                'email':TARGET,'permissions':permissions,'allowed_branches':['B1']})
            assert response.status_code==expected,response.text
            if expected==200:
                assert source.commits==1 and source.records[TARGET]['permissions']==permissions
                assert source.records[TARGET]['allowed_branches']==['B1']
                assert notices==[(target_company,TARGET)]
            else:
                assert source.commits==0 and not notices and source.records[TARGET]==before
    asyncio.run(run())

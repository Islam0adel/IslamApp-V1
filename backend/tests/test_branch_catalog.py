"""Both existing branch catalogs reach all new policy/account boundaries."""
import asyncio
import copy
import pytest
from sqlalchemy import delete
from app.core import models
from app.core.branch_catalog import company_branch_catalog
from app.core.startup_branch import validate_startup_branch
from test_permission_editor_integration import fixture,TARGET
from test_management_directory import install
from test_company_policy_review import CONFIG

@pytest.mark.parametrize('active',[False,True])
def test_coding_only_branch_is_visible_valid_and_does_not_grant_scope(tmp_path,monkeypatch,active):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=active) as (client,source,factory,_):
            install(source)
            source.patch(TARGET,allowed_branches=['all'],branch_code='1')
            async with factory() as db:
                await db.execute(delete(models.Branch))
                db.add_all([models.CodingRecord(company_code=company,category='branches',code=code,name=name,is_deleted=deleted)
                    for company,code,name,deleted in [('C1','1','Main',False),('C1','2','Second',False),('C1','3','Deleted',True),('C2','9','Other company',False)]])
                await db.commit()
            before=copy.deepcopy(source.records[TARGET])
            value=(await client.get('/auth/permission-editor/'+TARGET)).json()
            assert value['branch_choices']==[{'code':'1','name':'Main'},{'code':'2','name':'Second'}]
            assert value['allowed_branches']==['all'] and value['startup_branch_code']=='1'
            account=(await client.get('/auth/user-editor/'+TARGET)).json()
            assert account['branch_choices']==value['branch_choices']
            review=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            assert review['branches']==value['branch_choices']
            assert source.records[TARGET]==before
            async with factory() as db:
                assert await validate_startup_branch(db,company_code='C1',value='1',allowed_branches=['all'])=='1'
            source.patch(TARGET,allowed_branches=['1'])
            limited=(await client.get('/auth/user-editor/'+TARGET)).json()
            assert limited['branch_choices']==[{'code':'1','name':'Main'}]
    asyncio.run(run())


def test_coding_only_branches_work_in_draft_activation_and_invitation(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,factory,_):
            from test_account_lifecycle import lifecycle_source
            lifecycle_source(source,monkeypatch)
            install(source);source.patch(TARGET,role='admin',allowed_branches=['B2'])
            async with factory() as db:
                await db.execute(delete(models.Branch))
                db.add_all([models.CodingRecord(company_code='C1',category='branches',code=code,name=code,is_deleted=False) for code in ['B1','B2']]);await db.commit()
            saved=await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':0,'configuration':CONFIG})
            assert saved.status_code==200,saved.text
            review=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            response=await client.post('/auth/companies/C1/permission-policy/activate',json={'expected_revision':1,'source_review_token':review['source_review_token'],'confirmed_review':True})
            assert response.status_code==200,response.text
            # Root invitation uses actual coding branch, without converting all.
            response=await client.post('/auth/admin/add-user',json={'email':'coded@example.com','name':'Coded','company_code':'C1','role':'employee','branch_code':'B2'})
            assert response.status_code==200,response.text
            assert source.records['coded@example.com']['allowed_branches']==['B2']
    asyncio.run(run())


def test_catalog_keeps_legacy_support_and_one_identity_for_duplicate_code(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (_,source,factory,_):
            async with factory() as db:
                db.add(models.CodingRecord(company_code='C1',category='branches',code='B2',name='Current coding name',is_deleted=False));await db.commit()
                catalog=await company_branch_catalog(db,'C1',lock=True)
                assert catalog=={'B1':'B1','B2':'Current coding name','B3':'B3'}
    asyncio.run(run())


def test_actual_coding_save_reaches_permission_choices_without_copying_data(tmp_path,monkeypatch):
    from app.routes import coding
    from app.core.schemas import CodingModel
    from types import SimpleNamespace
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(coding.manager,'broadcast',quiet)
    async def run():
        async with fixture(tmp_path,monkeypatch,root=True,active=False) as (client,source,factory,_):
            source.patch(TARGET,allowed_branches=['all'],branch_code='1')
            async with factory() as db:
                await db.execute(delete(models.Branch));await db.commit()
                actor=SimpleNamespace(state=SimpleNamespace(auth_user={'role':'super_admin','company_code':'C1'}))
                result=await coding.save_code(CodingModel(company_code='C1',category='branches',code='1',name='Saved branch'),actor,db)
                assert result['status']=='success'
                assert (await db.execute(models.Branch.__table__.select())).all()==[]
            value=(await client.get('/auth/permission-editor/'+TARGET)).json()
            assert value['startup_branch_code']=='1' and value['allowed_branches']==['all']
            assert value['branch_choices']==[{'code':'1','name':'Saved branch'}]
    asyncio.run(run())

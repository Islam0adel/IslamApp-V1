"""Account metadata authority locks against disposable PostgreSQL."""
import asyncio
import threading
from types import SimpleNamespace
import pytest
from sqlalchemy import update
from app.core import models
from app.routes import auth
from test_postgres_save_concurrency import URL, run_case
from test_permission_editor_integration import fixture, TARGET
from test_account_editor import load, grant, EDIT

pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')

@pytest.mark.parametrize('locked_row',['company','policy','branch','coded-branch','cancelled-request','cancelled-asgi'])
def test_metadata_authority_locks_live_until_source_write_settles(locked_row,tmp_path,monkeypatch):
    async def work(factory):
        async with fixture(tmp_path,monkeypatch,provided_factory=factory) as (client,source,_,notices):
            if locked_row=='coded-branch':
                from sqlalchemy import delete
                async with factory() as db:
                    await db.execute(delete(models.Branch))
                    db.add_all([models.CodingRecord(company_code='C1',category='branches',code=code,name=code,is_deleted=False) for code in ['B1','B2']]);await db.commit()
            await grant(factory,[EDIT]);_,data=await load(client);data.update(name='Saved',branch_code='B2')
            entered=asyncio.Event();release=threading.Event();loop=asyncio.get_running_loop()
            def gate():
                loop.call_soon_threadsafe(entered.set)
                assert release.wait(8),'source commit gate timed out'
            source.before_commit=gate
            async def mutation():
                if locked_row!='cancelled-request':return await client.put('/auth/admin/edit-user',json=data)
                async with factory() as db:
                    request=SimpleNamespace(state=SimpleNamespace(auth_user=source.cached_actor))
                    return await auth.admin_edit_user(auth.AdminEditUserModel(**data),request,db)
            saving=asyncio.create_task(mutation());changing=None
            try:
                await asyncio.wait_for(entered.wait(),5);started=asyncio.Event()
                async def authority_change():
                    async with factory() as db:
                        started.set()
                        if locked_row=='company':await db.execute(update(models.Company).where(models.Company.code=='C1').values(is_active=False))
                        elif locked_row=='coded-branch':await db.execute(update(models.CodingRecord).where(models.CodingRecord.company_code=='C1',models.CodingRecord.category=='branches',models.CodingRecord.code=='B2').values(name='Renamed'))
                        elif locked_row=='branch':await db.execute(update(models.Branch).where(models.Branch.company_code=='C1',models.Branch.code=='B2').values(name='Renamed'))
                        else:await db.execute(update(models.CompanyPermissionPolicy).where(models.CompanyPermissionPolicy.company_code=='C1').values(active_revision=2))
                        await db.commit()
                changing=asyncio.create_task(authority_change());await started.wait();await asyncio.sleep(.15)
                assert not changing.done(),'authority changed during the protected source write'
                if locked_row.startswith('cancelled'):
                    saving.cancel();await asyncio.sleep(.15)
                    assert not saving.done() and not changing.done() and source.commits==0
                release.set()
                if locked_row.startswith('cancelled'):
                    with pytest.raises(asyncio.CancelledError):await saving
                else:
                    response=await saving;assert response.status_code==200,response.text
                await asyncio.wait_for(changing,5)
                assert source.commits==1 and source.records[TARGET]['name']=='Saved'
                assert source.records[TARGET]['allowed_branches']==['B2'] and notices==[('C1',TARGET)]
            finally:
                release.set();await asyncio.gather(saving,*([changing] if changing else []),return_exceptions=True)
    asyncio.run(run_case(work))

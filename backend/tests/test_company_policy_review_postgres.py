"""PostgreSQL reviewed activation serializes with source-authority writers."""
import asyncio
import threading
import pytest
from sqlalchemy import select,update
from app.core import models
from app.core.company_policy_review import activate_review
from app.routes import auth
from test_postgres_save_concurrency import URL,run_case
from test_permission_editor_integration import fixture,ACTOR,TARGET
from test_management_directory import install
from test_company_policy_review import CONFIG

pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')

@pytest.mark.parametrize('row',['company','actor-company','policy','branch'])
def test_review_activation_holds_authority_locks_through_commit(row,tmp_path,monkeypatch):
    async def work(factory):
        async with fixture(tmp_path,monkeypatch,root=True,active=False,provided_factory=factory) as (client,source,_,_):
            install(source);source.patch(TARGET,role='admin')
            if row=='actor-company':
                async with factory() as db:db.add(models.Company(code='ROOT',name='Root company'));await db.commit()
                source.patch(ACTOR,company_code='ROOT')
            saved=await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':0,'configuration':CONFIG})
            assert saved.status_code==200,saved.text
            review=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            entered=asyncio.Event();release=threading.Event();loop=asyncio.get_running_loop()
            def gate():loop.call_soon_threadsafe(entered.set);assert release.wait(8)
            source.during_scan=gate
            async def activate():
                async with factory() as db:
                    return await activate_review(db,source,source.cached_actor,'C1',auth._effective_role,1,review['source_review_token'])
            reading=asyncio.create_task(activate());changing=None
            try:
                await asyncio.wait_for(entered.wait(),5);started=asyncio.Event()
                async def change():
                    async with factory() as db:
                        started.set()
                        if row in ('company','actor-company'):
                            await db.execute(update(models.Company).where(models.Company.code==('ROOT' if row=='actor-company' else 'C1')).values(is_active=False))
                        elif row=='policy':await db.execute(update(models.CompanyPermissionPolicy).where(models.CompanyPermissionPolicy.company_code=='C1').values(revision=3))
                        else:await db.execute(update(models.Branch).where(models.Branch.company_code=='C1',models.Branch.code=='B2').values(name='Renamed'))
                        await db.commit()
                changing=asyncio.create_task(change());await started.wait();await asyncio.sleep(.15)
                assert not changing.done(),'authority changed during protected review'
                release.set();result=await reading;assert result['authorization_changed']
                await asyncio.wait_for(changing,5)
            finally:
                release.set();await asyncio.gather(reading,*([changing] if changing else []),return_exceptions=True)
    asyncio.run(run_case(work))


def test_double_activation_has_one_revision_winner(tmp_path,monkeypatch):
    async def work(factory):
        async with fixture(tmp_path,monkeypatch,root=True,active=False,provided_factory=factory) as (client,source,_,_):
            install(source);source.patch(TARGET,role='admin')
            await client.put('/auth/companies/C1/permission-policy/draft',json={'expected_revision':0,'configuration':CONFIG})
            review=(await client.get('/auth/companies/C1/permission-policy/review')).json()
            async def activate():
                async with factory() as db:
                    try:await activate_review(db,source,source.cached_actor,'C1',auth._effective_role,1,review['source_review_token']);return 200
                    except Exception as exc:return getattr(exc,'status_code',500)
            results=await asyncio.gather(activate(),activate())
            assert sorted(results)==[200,409],results
            async with factory() as db:
                row=await db.get(models.CompanyPermissionPolicy,'C1');assert row.active_revision==2 and row.revision==2
    asyncio.run(run_case(work))

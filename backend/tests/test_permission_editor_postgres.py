"""Actual PostgreSQL authority locks; source storage is deliberately synthetic."""
import asyncio
import threading
from types import SimpleNamespace
import pytest
from sqlalchemy import update
from app.core import models, permission_editor as editor
from app.routes import auth
from test_postgres_save_concurrency import URL, run_case
from test_permission_editor_integration import fixture, load, TARGET, VIEW

pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')


@pytest.mark.parametrize('locked_row',['company','policy','cancelled-request','cancelled-asgi','admin-policy','admin-cancelled-asgi'])
def test_authority_writers_wait_until_source_commit_settles(locked_row,tmp_path,monkeypatch):
    async def work(factory):
        async with fixture(tmp_path,monkeypatch,provided_factory=factory) as (client,source,_,notices):
            admin_target = locked_row.startswith('admin-')
            if admin_target: source.patch(TARGET,role='admin')
            _,data=await load(client); data['permissions']=VIEW
            entered=asyncio.Event(); release=threading.Event(); loop=asyncio.get_running_loop()
            def gate():
                loop.call_soon_threadsafe(entered.set)
                assert release.wait(8),'source-commit gate timed out'
            source.before_commit=gate
            async def mutation():
                if locked_row!='cancelled-request':
                    return await client.post('/auth/update-permissions',json=data)
                async with factory() as db:
                    request=SimpleNamespace(state=SimpleNamespace(auth_user=source.cached_actor))
                    return await auth.update_user_permissions(auth.PermissionsUpdateModel(**data),request,db)
            saving=asyncio.create_task(mutation())
            changing=None
            try:
                await asyncio.wait_for(entered.wait(),5)
                started=asyncio.Event()
                async def authority_change():
                    async with factory() as db:
                        started.set()
                        if locked_row=='company':
                            await db.execute(update(models.Company).where(models.Company.code=='C1').values(is_active=False))
                        else:
                            await db.execute(update(models.CompanyPermissionPolicy).where(
                                models.CompanyPermissionPolicy.company_code=='C1').values(active_revision=2))
                        await db.commit()
                changing=asyncio.create_task(authority_change())
                await started.wait()
                await asyncio.sleep(0.15)
                assert not changing.done(),'authority changed before the protected source commit'
                if 'cancelled' in locked_row:
                    saving.cancel()
                    await asyncio.sleep(0.15)
                    assert not saving.done(),'cancelled request released its SQL authority locks too soon'
                    assert not changing.done()
                    assert source.commits==0
                release.set()
                if 'cancelled' in locked_row:
                    with pytest.raises(asyncio.CancelledError): await saving
                else:
                    response=await saving
                    assert response.status_code==200,response.text
                await asyncio.wait_for(changing,5)
                assert source.commits==1
                if admin_target:
                    assert source.records[TARGET]['permissions']=={}
                    async with factory() as db:
                        row=await db.get(models.CompanyPermissionPolicy,'C1')
                        assert row.active['admin_profiles']['target-uid']['operating_permissions']==VIEW
                        assert row.active['admin_profiles']['actor-uid']['delegable_permissions']==VIEW
                else: assert source.records[TARGET]['permissions']==VIEW
                assert notices==[('C1',TARGET)]
                async with factory() as db:
                    if locked_row=='company': assert not (await db.get(models.Company,'C1')).is_active
                    else: assert (await db.get(models.CompanyPermissionPolicy,'C1')).active_revision==2
            finally:
                release.set()
                await asyncio.gather(saving,*([changing] if changing else []),return_exceptions=True)
    asyncio.run(run_case(work))

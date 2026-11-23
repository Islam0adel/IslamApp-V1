"""Real SQL lifecycle authority locks, synthetic versioned source and Auth."""
import asyncio
import threading
import pytest
from sqlalchemy import update, select
from app.core import models
from test_postgres_save_concurrency import URL, run_case
from test_permission_editor_integration import fixture, TARGET
from test_management_directory import grant
from test_account_lifecycle import lifecycle_source
from app.routes import auth

pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')

@pytest.mark.parametrize('action',['delete','reset','reject','add','approve','bind','verify','cancel'])
@pytest.mark.parametrize('row',['company','policy'])
def test_lifecycle_holds_current_authority_until_source_write(action,row,tmp_path,monkeypatch):
    async def work(factory):
        async with fixture(tmp_path,monkeypatch,provided_factory=factory) as (client,source,_,_):
            lifecycle_source(source,monkeypatch);await grant(factory,[action] if action in ('add','approve','delete','reset','reject') else [])
            source.requests['r1'].update(email='new@example.com',name='New')
            if action in ('bind','verify','cancel'):
                source.records[TARGET].update(uid='' if action=='bind' else 'target-uid',email=TARGET,status='pending',requires_email_verification=True)
            entered=asyncio.Event();release=threading.Event();loop=asyncio.get_running_loop()
            def gate():
                loop.call_soon_threadsafe(entered.set)
                assert release.wait(8)
            source.before_lifecycle_commit=gate
            async def send():
                if action=='delete':return await client.delete('/auth/admin/delete-user',params={'email':TARGET})
                if action=='reset':return await client.post('/auth/admin/reset-pending-user',params={'email':TARGET})
                if action in ('add','approve'):
                    payload={'email':'new@example.com','name':'New','role':'employee','branch_code':'B2','company_code':'C1'}
                    return await client.post('/auth/admin/add-user' if action=='add' else '/auth/admin/registration-requests/r1/approve',json=payload)
                if action in ('bind','verify','cancel'):
                    from app.core.invitation_binding import bind_invitation,verify_invited_account,cancel_invited_account
                    async with factory() as db:
                        if action=='bind':await bind_invitation(db,source,TARGET,TARGET,'target-uid','',auth._effective_role)
                        elif action=='verify':await verify_invited_account(db,source,TARGET,'target-uid')
                        else:
                            async def quiet(*args):pass
                            await cancel_invited_account(db,source,TARGET,'target-uid',auth.admin_auth,quiet)
                        await db.rollback()
                    from types import SimpleNamespace
                    return SimpleNamespace(status_code=200,text='')
                return await client.post('/auth/admin/registration-requests/r1/reject')
            reading=asyncio.create_task(send());changing=None
            try:
                await asyncio.wait_for(entered.wait(),5);started=asyncio.Event()
                async def change():
                    async with factory() as db:
                        started.set()
                        if row=='company':await db.execute(update(models.Company).where(models.Company.code=='C1').values(is_active=False))
                        else:await db.execute(update(models.CompanyPermissionPolicy).where(models.CompanyPermissionPolicy.company_code=='C1').values(active_revision=2))
                        await db.commit()
                changing=asyncio.create_task(change());await started.wait();await asyncio.sleep(.15)
                assert not changing.done()
                release.set();response=await reading
                # A company stop after the HR commit can correctly hold finalization.
                assert response.status_code in (200,403),response.text
                if response.status_code==403:assert source.records[TARGET]['is_active'] is False
                await asyncio.wait_for(changing,5)
            finally:
                release.set();await asyncio.gather(reading,*([changing] if changing else []),return_exceptions=True)
    asyncio.run(run_case(work))

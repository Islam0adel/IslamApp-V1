"""PostgreSQL row locks remain held throughout a permission-directory scan."""
import asyncio
import threading
import pytest
from sqlalchemy import update
from app.core import models
from test_postgres_save_concurrency import URL, run_case
from test_permission_editor_integration import fixture
from test_permission_directory import install
pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')

@pytest.mark.parametrize('row',['company','policy'])
def test_directory_source_scan_holds_its_sql_authority_snapshot(row,tmp_path,monkeypatch):
    async def work(factory):
        async with fixture(tmp_path,monkeypatch,provided_factory=factory) as (client,source,_,_):
            install(source,monkeypatch)
            entered=asyncio.Event(); release=threading.Event(); loop=asyncio.get_running_loop()
            def gate():
                loop.call_soon_threadsafe(entered.set)
                assert release.wait(8),'directory source gate timed out'
            source.after_scan=gate
            reading=asyncio.create_task(client.get('/auth/permission-editor-targets?company_code=C1'))
            changing=None
            try:
                await asyncio.wait_for(entered.wait(),5)
                started=asyncio.Event()
                async def write():
                    async with factory() as session:
                        started.set()
                        if row=='company': await session.execute(update(models.Company).where(models.Company.code=='C1').values(is_active=False))
                        else: await session.execute(update(models.CompanyPermissionPolicy).where(models.CompanyPermissionPolicy.company_code=='C1').values(active_revision=2))
                        await session.commit()
                changing=asyncio.create_task(write());await started.wait();await asyncio.sleep(0.15)
                assert not changing.done(),'directory authority changed during its source scan'
                release.set();response=await reading
                assert response.status_code==200,response.text
                await asyncio.wait_for(changing,5)
            finally:
                release.set()
                await asyncio.gather(reading,*([changing] if changing else []),return_exceptions=True)
    asyncio.run(run_case(work))

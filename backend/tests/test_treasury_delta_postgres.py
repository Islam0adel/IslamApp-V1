"""Opt-in local PostgreSQL revision/commit ordering and old-client compatibility."""
import asyncio
import pytest
from sqlalchemy import select
from app.core.models import TreasurySyncEntry, TreasurySyncState
from app.core.treasury_sync import lock_state
from app.routes import treasury_transfers as route
from test_treasury_transfers import req, data, changed
from test_postgres_save_concurrency import URL, run_case
pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')


def test_clock_blocks_snapshot_until_writer_commit_and_next_delta_is_not_skipped(monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(route.manager,'broadcast',quiet)
    async def work(factory):
        async with factory() as seed:
            await route.save_transfer(req(),data(),seed)
            initial=await route.treasury_changes(req(),'records','C1',0,'',seed)
        entered=asyncio.Event();release=asyncio.Event()
        async def writer():
            async with factory() as db:
                state=await lock_state(db,'C1');entered.set();await release.wait()
                # The normal writer joins its own held clock and commits change.
                record=(await route.list_transfers(req(),'C1',db=db))[0]
                await route.save_transfer(req(),changed(data(),amount=71,serial=1,base_updated_at=record['updated_at']),db)
        w=asyncio.create_task(writer());await entered.wait()
        async def read():
            async with factory() as db:return await route.treasury_changes(req(),'records','C1',initial['cursor'],initial['scope'],db)
        r=asyncio.create_task(read());await asyncio.sleep(.1)
        assert not r.done();release.set();await w;delta=await r
        assert len(delta['items'])==1 and delta['items'][0]['amount']==71
        async with factory() as db:
            assert await route.treasury_changes(req(),'records','C1',delta['cursor'],delta['scope'],db)=={
                **delta,'items':[]}
    asyncio.run(run_case(work))


def test_concurrent_legacy_api_writers_are_revisioned_without_duplicate_effects(monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(route.manager,'broadcast',quiet)
    async def work(factory):
        async def save(index):
            async with factory() as db:
                return await route.save_transfer(req(),changed(data(),id='T'+str(index)),db)
        saved=await asyncio.gather(*(save(i) for i in range(8)))
        assert sorted(r['record']['serial'] for r in saved)==list(range(1,9))
        async with factory() as db:
            snap=await route.treasury_changes(req(),'records','C1',0,'',db)
            assert len(snap['items'])==8 and snap['cursor']==8
            legacy=await route.transfer_effects(req(),'C1',db)
            assert sorted((e['treasury'],e['signed_amount']) for e in legacy)==[('A',-802.0),('B',802.0)]
            assert len(list(await db.scalars(select(TreasurySyncEntry))))==8
    asyncio.run(run_case(work))

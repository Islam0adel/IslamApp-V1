"""Opt-in regression suite for the private disposable PostgreSQL fixture.

Set ISLAMAPP_TEST_POSTGRES to the local Unix-socket fixture URL. Never use a
work database. Each case creates and drops only its own randomized test schema.
"""
import asyncio
import os
import uuid
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models, schemas
from app.routes import commercial, supplier_settlement, transactions

URL=os.environ.get('ISLAMAPP_TEST_POSTGRES','')
pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')


def request(payload=None):
    async def body(): return payload
    return SimpleNamespace(state=SimpleNamespace(auth_user={'uid':'fixture-owner','role':'admin','company_code':'C1'}),json=body)


def journal():
    return schemas.TransactionModel(company_code='C1',branch_code='B1',serial=0,treasury='A',amount=10,statement='test',category='Income',date='2026-11-22',type='وارد')


def sale(identifier):
    return {'id':identifier,'company_code':'C1','branch_code':'B1','store_code':'S1','date':'2026-11-22','items':[{'code':'P1','quantity':1,'price':10,'total':10}],'subtotal':10,'discount':0,'total':10,'paid':10,'due':0,'payments':[{'method':'cash','treasury':'A','amount':10}]}


async def run_case(work):
    assert URL.startswith('postgresql+asyncpg://islamapp_test@/postgres?host=/tmp/islamapp-pg-socket&port='), 'Only the isolated local test cluster is permitted'
    schema='islamapp_test_'+uuid.uuid4().hex
    engine=create_async_engine(URL,pool_size=12,max_overflow=4,connect_args={'server_settings':{'search_path':schema}})
    factory=async_sessionmaker(engine,expire_on_commit=False)
    try:
        async with engine.begin() as conn:
            await conn.execute(text('CREATE SCHEMA '+schema))
            await conn.run_sync(models.Base.metadata.create_all)
        await asyncio.wait_for(work(factory),30)
    finally:
        async with engine.begin() as conn:await conn.execute(text('DROP SCHEMA IF EXISTS '+schema+' CASCADE'))
        await engine.dispose()


@pytest.mark.parametrize('kind',['sales','journal','settlement'])
def test_distinct_concurrent_saves_keep_all_valid_records_and_serials(kind,monkeypatch):
    async def quiet(*a,**k):pass
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        async def save(index):
            async with factory() as db:
                if kind=='sales':return await commercial.save_kind('sales',request(sale('s'+str(index))),db)
                if kind=='journal':return await transactions.save_transaction(request(),journal(),db)
                data=schemas.SupplierSettlementModel(company_code='C1',branch_code='B1',serial=0,supplier_name='Supplier',payment_method='cash',treasury='A',amount=10,statement='test',date='2026-11-22')
                return await supplier_settlement.save_settlement(request(),data,db)
        results=await asyncio.gather(*[save(i) for i in range(8)])
        assert all(result['status']=='success' for result in results)
        model={'sales':models.SaleRecord,'journal':models.Transaction,'settlement':models.SupplierSettlementRecord}[kind]
        async with factory() as db:
            serials=list((await db.scalars(select(model.serial))).all())
            assert sorted(serials)==list(range(1,9))
    asyncio.run(run_case(work))


def test_concurrent_same_sale_id_has_one_row_not_unique_key_500(monkeypatch):
    async def quiet(*a,**k):pass
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        async def save():
            async with factory() as db:return await commercial.save_kind('sales',request(sale('same')),db)
        results=await asyncio.gather(*[save() for _ in range(8)])
        assert len({result['serial'] for result in results})==1
        async with factory() as db:assert len(list(await db.scalars(select(models.SaleRecord))))==1
    asyncio.run(run_case(work))


def test_linked_journal_and_settlement_writers_share_serial_locks(monkeypatch):
    async def quiet(*a,**k):pass
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        async def save(index):
            async with factory() as db:
                if index%2==0:
                    data=journal().model_copy(update={'category':'بضاعة','add_to_settlement':True,'supplier_name':'Supplier'})
                    return await transactions.save_transaction(request(),data,db)
                data=schemas.SupplierSettlementModel(company_code='C1',branch_code='B1',serial=0,supplier_name='Supplier',payment_method='cash',treasury='A',amount=10,statement='test',date='2026-11-22',add_to_daily=True,link_id='link-'+str(index))
                return await supplier_settlement.save_settlement(request(),data,db)
        results=await asyncio.gather(*[save(i) for i in range(8)])
        assert all(result['status']=='success' for result in results)
        async with factory() as db:
            for model in [models.Transaction,models.SupplierSettlementRecord]:
                assert sorted(await db.scalars(select(model.serial)))==list(range(1,9))
    asyncio.run(run_case(work))


def test_sale_delete_and_save_do_not_resurrect_deleted_record(monkeypatch):
    async def quiet(*a,**k):pass
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        async with factory() as db:await commercial.save_kind('sales',request(sale('same')),db)
        async def save():
            async with factory() as db:
                try:return await commercial.save_kind('sales',request(sale('same')),db)
                except HTTPException as error:assert error.status_code==404
        async def delete():
            async with factory() as db:return await commercial.delete_kind('sales','C1','same',request(),db)
        await asyncio.gather(save(),delete())
        async with factory() as db:assert (await db.get(models.SaleRecord,'same')).is_deleted
    asyncio.run(run_case(work))


@pytest.mark.parametrize('same_intent',[True,False])
def test_journal_receipts_are_atomic_for_concurrent_retries(same_intent,monkeypatch):
    broadcasts=[]
    async def quiet(*args,**kwargs):broadcasts.append(args)
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        async def save(index):
            payload=journal().model_copy(update={'operation_id':'journal-operation-'+str(0 if same_intent else index)})
            async with factory() as db:return await transactions.save_transaction(request(),payload,db)
        results=await asyncio.gather(*[save(index) for index in range(8)])
        assert all(result['status']=='success' for result in results)
        expected=1 if same_intent else 8
        assert len(broadcasts)==expected
        async with factory() as db:
            assert sorted(await db.scalars(select(models.Transaction.serial)))==list(range(1,expected+1))
            assert len(list(await db.scalars(select(models.JournalSaveReceipt))))==expected
    asyncio.run(run_case(work))


def test_status_waits_for_inflight_commit_before_reporting_absence(monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        ready=asyncio.Event()
        release=asyncio.Event()
        payload=journal().model_copy(update={'operation_id':'journal-operation-wait'})
        async with factory() as saving:
            real_commit=saving.commit
            async def paused_commit():
                ready.set()
                await release.wait()
                await real_commit()
            monkeypatch.setattr(saving,'commit',paused_commit)
            saving_task=asyncio.create_task(transactions.save_transaction(request(),payload,saving))
            await ready.wait()
            async with factory() as reading:
                status_task=asyncio.create_task(transactions.journal_save_status(request(),'C1','journal-operation-wait',branch_code='B1',db=reading))
                try:
                    await asyncio.sleep(0.05)
                    waited = not status_task.done()
                finally:
                    release.set()
                saved=await saving_task
                status=await status_task
                assert waited
                assert status['committed'] is True
                assert status['serial']==saved['serial']
    asyncio.run(run_case(work))


@pytest.mark.parametrize('can_view',[False,True])
def test_add_only_owner_can_retry_its_unchanged_sale_without_edit_grant(can_view,monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(commercial.manager,'broadcast',quiet)
    async def work(factory):
        async with factory() as db:
            db.add(models.CodingRecord(company_code='C1',branch_code='B1',category='items',code='P1',name='fixture',selling_price=10,cost_pending=False))
            await db.commit()
        async def save():
            payload=sale('add-only-sale')
            actor=request(payload)
            actor.state.auth_user.update(role='employee',allowed_branches=['B1'],permissions={'المبيعات':{'إضافة':True,'معاينة':can_view}})
            async with factory() as db:return await commercial.save_kind('sales',actor,db)
        results=await asyncio.gather(*[save() for _ in range(8)],return_exceptions=True)
        async with factory() as db:assert len(list(await db.scalars(select(models.SaleRecord))))==1
        failures=[str(result) for result in results if isinstance(result,BaseException)]
        assert not failures,failures
        assert len(results)==8
        assert len({result['serial'] for result in results})==1
    asyncio.run(run_case(work))


def test_journal_two_edits_from_same_base_have_one_winner(monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(transactions.manager,'broadcast',quiet)
    async def work(factory):
        async with factory() as db:
            first=await transactions.save_transaction(request(),journal(),db)
        async def edit(index):
            payload=journal().model_copy(update={'serial':first['serial'],'amount':20+index,
                'operation_id':'journal-version-concurrent-'+str(index),'base_updated_at':first['record']['updated_at']})
            async with factory() as db:
                try:return await transactions.save_transaction(request(),payload,db)
                except HTTPException as exc:return exc.status_code
        results=await asyncio.gather(edit(1),edit(2))
        assert sum(isinstance(result,dict) for result in results)==1
        assert results.count(409)==1
        async with factory() as db:
            assert len(list(await db.scalars(select(models.Transaction))))==1
            assert len(list(await db.scalars(select(models.JournalSaveReceipt))))==1
    asyncio.run(run_case(work))

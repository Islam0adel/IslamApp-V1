"""Actual commercial create/retry handlers with synthetic SQL identities."""
import asyncio
import copy
from contextlib import asynccontextmanager
from datetime import datetime
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models
from app.routes import commercial


def payload(kind='sales', identifier='doc1'):
    common={'id':identifier,'company_code':'C1','branch_code':'B1','date':'2026-11-22'}
    if kind=='sales':
        return {**common,'store_code':'S1','items':[{'code':'P1','quantity':1,'price':10,'total':10}],
                'subtotal':10,'total':10,'paid':10,'payments':[{'method':'cash','treasury':'A','amount':10}]}
    if kind=='returns':
        return {**common,'store_code':'S1','items':[{'code':'P1','quantity':1,'price':10}],
                'total':10,'payments':[{'method':'cash','treasury':'A','amount':10}]}
    if kind=='customer-payments':
        return {**common,'customer_name':'Fixture','amount':10,'payments':[{'method':'cash','treasury':'A','amount':10}]}
    common.pop('branch_code')
    return {**common,'from_branch_code':'B1','to_branch_code':'B1','from_store_code':'S1',
            'to_store_code':'S2','items':[{'code':'P1','quantity':1}]}


def request(data, kind='sales', **changes):
    category=commercial.CONFIG[kind][2]
    key='إضافة تحصيل' if kind=='customer-payments' else 'إضافة'
    profile={'uid':'owner','company_code':'C1','role':'employee','company_policy_active':True,
             'allowed_branches':['B1'],'permissions':{category:{key:True}}}
    profile.update(changes)
    async def body(): return copy.deepcopy(data)
    return SimpleNamespace(state=SimpleNamespace(auth_user=profile),json=body)

@asynccontextmanager
async def fixture(tmp_path,monkeypatch):
    engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'receipts.db'))
    factory=async_sessionmaker(engine,expire_on_commit=False)
    async with engine.begin() as conn: await conn.run_sync(models.Base.metadata.create_all)
    async with factory() as db:
        db.add(models.CodingRecord(company_code='C1',branch_code='B1',category='items',code='P1',name='Fixture',selling_price=10,cost_pending=False))
        await db.commit()
    broadcasts=[]
    async def broadcast(*args): broadcasts.append(args)
    monkeypatch.setattr(commercial.manager,'broadcast',broadcast)
    try: yield factory,broadcasts
    finally: await engine.dispose()

@pytest.mark.parametrize('kind',list(commercial.CONFIG))
def test_owner_with_add_only_gets_summary_ack_without_edit_or_duplicate_broadcast(kind,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (factory,broadcasts):
            data=payload(kind)
            async with factory() as db:
                first=await commercial.save_kind(kind,request(data,kind),db)
            async with factory() as db:
                again=await commercial.save_kind(kind,request(data,kind),db)
            assert first['action']=='insert' and again['action']=='unchanged'
            assert first['serial']==again['serial']==1 and first['updated_at']==again['updated_at']
            assert set(again)=={'status','id','serial','updated_at','action'}
            assert len(broadcasts)==1
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(commercial.CONFIG[kind][0]))==1
                assert await db.scalar(select(func.count()).select_from(models.CommercialCreationReceipt))==1
    asyncio.run(run())

@pytest.mark.parametrize('change',['other-owner','payload','serial','branch-revoked','add-revoked',
                                  'deleted','edited','missing-receipt','different-company','stale-base'])
def test_receipt_never_turns_retry_into_an_edit_or_data_access_grant(change,tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (factory,broadcasts):
            data=payload()
            async with factory() as db: await commercial.save_kind('sales',request(data),db)
            options={}; expected=403
            if change=='other-owner': options['uid']='someone-else'
            if change=='payload': data['customer_name']='Changed customer'
            if change=='serial': data['serial']=999
            if change=='branch-revoked': options['allowed_branches']=['B2']
            if change=='add-revoked': options['permissions']={'المبيعات':{'معاينة':True}}
            if change=='different-company': data['company_code']='C2'; options['company_code']='C2'; expected=404
            if change=='stale-base': data['base_updated_at']='2000-01-01T00:00:00'; expected=409
            if change in ('deleted','edited','missing-receipt'):
                async with factory() as db:
                    if change=='missing-receipt':
                        await db.delete(await db.get(models.CommercialCreationReceipt,('sales','doc1')))
                    else:
                        record=await db.get(models.SaleRecord,'doc1')
                        if change=='deleted': record.is_deleted=True; expected=404
                        else: record.customer_name='Changed by an editor'; record.updated_at=datetime(2026,11,23)
                    await db.commit()
            async with factory() as db:
                with pytest.raises(HTTPException) as failure:
                    await commercial.save_kind('sales',request(data,**options),db)
                assert failure.value.status_code==expected
            assert len(broadcasts)==1
    asyncio.run(run())


def test_serial_ack_number_representation_and_catalog_change_do_not_break_original_retry(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (factory,broadcasts):
            data=payload()
            async with factory() as db: first=await commercial.save_kind('sales',request(data),db)
            async with factory() as db:
                item=await db.scalar(select(models.CodingRecord)); item.selling_price=20; await db.commit()
            data['serial']=first['serial']; data['items'][0].update(quantity=1.0,price=10.0,total=10.0)
            data['payments'][0]['amount']=10.0
            async with factory() as db: again=await commercial.save_kind('sales',request(data),db)
            assert again['action']=='unchanged' and len(broadcasts)==1
    asyncio.run(run())


def test_edit_holder_can_make_real_edit_but_original_creation_receipt_stays_immutable(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (factory,broadcasts):
            data=payload()
            async with factory() as db: await commercial.save_kind('sales',request(data),db)
            changed=copy.deepcopy(data); changed['customer_name']='Edited'
            async with factory() as db:
                result=await commercial.save_kind('sales',request(changed,permissions={'المبيعات':{'تعديل':True}}),db)
                assert result['action']=='update'
            async with factory() as db:
                with pytest.raises(HTTPException) as error: await commercial.save_kind('sales',request(data),db)
                assert error.value.status_code==403
            assert len(broadcasts)==2
    asyncio.run(run())


def test_failed_commit_rolls_back_record_and_creation_receipt_together(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (factory,broadcasts):
            async with factory() as db:
                async def fail(): raise RuntimeError('synthetic failed commit')
                monkeypatch.setattr(db,'commit',fail)
                with pytest.raises(HTTPException) as error: await commercial.save_kind('sales',request(payload()),db)
                assert error.value.status_code==500
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.SaleRecord))==0
                assert await db.scalar(select(func.count()).select_from(models.CommercialCreationReceipt))==0
            assert not broadcasts
    asyncio.run(run())


def test_nonfinite_payload_is_rejected_before_any_record_or_receipt_write(tmp_path,monkeypatch):
    async def run():
        async with fixture(tmp_path,monkeypatch) as (factory,broadcasts):
            data=payload(); data['total']=float('nan')
            async with factory() as db:
                with pytest.raises(HTTPException) as error: await commercial.save_kind('sales',request(data),db)
                assert error.value.status_code==400
                assert await db.scalar(select(func.count()).select_from(models.SaleRecord))==0
            assert not broadcasts
    asyncio.run(run())

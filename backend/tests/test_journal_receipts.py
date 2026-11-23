"""Owner-bound journal intention retries, using real temporary SQLite routes."""
import asyncio
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from sqlalchemy import event, select, func
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models, schemas
from app.routes import transactions

KEY='journal-intention-00001'

def data(**updates):
    return schemas.TransactionModel(**dict(company_code='C1',branch_code='B1',serial=0,treasury='A',amount=10,statement='test',category='Income',date='2026-11-22',type='وارد',operation_id=KEY,**updates))


def request(uid='owner',rights=None,company='C1',branches=None):
    profile={'uid':uid,'role':'employee','company_code':company,'allowed_branches':branches or ['B1','B2'],'permissions':{'حركة الخزينة':rights or {'ادخال اذون':True}}}
    return SimpleNamespace(state=SimpleNamespace(auth_user=profile))


@pytest.mark.parametrize('scenario',['exact','changed','other-owner','other-company','other-branch','branch-revoked','rights-revoked','deleted','newer-edit','distinct-intent','linked'])
def test_receipt_replay_scope_atomicity_and_current_snapshot(scenario,tmp_path,monkeypatch):
    broadcasts=[]
    async def notify(*args,**kwargs):broadcasts.append(args)
    monkeypatch.setattr(transactions.manager,'broadcast',notify)
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'journal.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        writes=[]
        @event.listens_for(engine.sync_engine,'before_cursor_execute')
        def record(conn,cursor,statement,parameters,context,many):
            if statement.lstrip().upper().startswith(('INSERT','UPDATE','DELETE')):writes.append(statement)
        async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as db:
                original=data()
                if scenario=='linked':original=original.model_copy(update={'category':'بضاعة','add_to_settlement':True,'supplier_name':'Supplier','link_id':'stable-link'})
                first=await transactions.save_transaction(request(),original,db)
                row=await db.scalar(select(models.Transaction))
                incoming=original.model_copy(deep=True)
                actor=request()
                expected=None
                if scenario=='changed':incoming.amount=20;expected=409
                if scenario=='other-owner':actor=request(uid='other');expected=403
                if scenario=='other-company':incoming.company_code='C2';actor=request(company='C2');expected=403
                if scenario=='other-branch':incoming.branch_code='B2';expected=403
                if scenario=='branch-revoked':actor=request(branches=['B2']);expected=403
                if scenario=='rights-revoked':actor=request(rights={'المعاينة':True});expected=403
                if scenario=='deleted':row.is_deleted=True;await db.commit();await db.refresh(row);expected=409
                if scenario=='newer-edit':
                    edit=original.model_copy(update={'serial':first['serial'],'operation_id':None,'amount':20})
                    await transactions.save_transaction(request(rights={'التعديل':True}),edit,db)
                    await db.refresh(row)
                if scenario=='distinct-intent':incoming.operation_id='journal-intention-00002'
                previous_time=row.updated_at
                before_broadcasts=len(broadcasts)
                writes.clear()
                if expected:
                    with pytest.raises(HTTPException) as error:await transactions.save_transaction(actor,incoming,db)
                    assert error.value.status_code==expected
                    await db.rollback()
                else:
                    replay=await transactions.save_transaction(actor,incoming,db)
                    assert replay['status']=='success'
                    assert replay['serial']==(2 if scenario=='distinct-intent' else first['serial'])
                    if scenario!='distinct-intent':assert replay['action']=='unchanged'
                    if scenario=='newer-edit':assert replay['record']['amount']==20
                if scenario!='distinct-intent':
                    assert writes==[]
                    assert len(broadcasts)==before_broadcasts
                    await db.refresh(row)
                    assert row.updated_at==previous_time
                assert await db.scalar(select(func.count()).select_from(models.Transaction))==(2 if scenario=='distinct-intent' else 1)
                assert await db.scalar(select(func.count()).select_from(models.JournalSaveReceipt))==(2 if scenario=='distinct-intent' else 1)
                if scenario=='linked':
                    assert await db.scalar(select(func.count()).select_from(models.SupplierSettlementRecord))==1
        finally:await engine.dispose()
    asyncio.run(work())


def test_missing_authenticated_owner_cannot_create_receipt(tmp_path,monkeypatch):
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'journal.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as db:
                with pytest.raises(HTTPException) as error:await transactions.save_transaction(request(uid=''),data(),db)
                assert error.value.status_code==403
                assert await db.scalar(select(func.count()).select_from(models.Transaction))==0
        finally:await engine.dispose()
    asyncio.run(work())


def test_failed_commit_rolls_back_journal_counterpart_and_receipt(tmp_path,monkeypatch):
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'journal.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as db:
                async def fail():raise RuntimeError('fixture commit failure')
                monkeypatch.setattr(db,'commit',fail)
                payload=data().model_copy(update={'category':'بضاعة','supplier_name':'Supplier','add_to_settlement':True,'link_id':'stable-link'})
                with pytest.raises(HTTPException) as error:await transactions.save_transaction(request(),payload,db)
                assert error.value.status_code==500
            async with factory() as db:
                for model in [models.Transaction,models.SupplierSettlementRecord,models.JournalSaveReceipt]:
                    assert await db.scalar(select(func.count()).select_from(model))==0
        finally:await engine.dispose()
    asyncio.run(work())


def test_notification_failure_after_commit_does_not_report_save_failure(tmp_path,monkeypatch):
    attempts=[]
    async def broken(*args,**kwargs):
        attempts.append(args)
        raise RuntimeError('fixture notification failure')
    monkeypatch.setattr(transactions.manager,'broadcast',broken)
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'journal.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as db:
                first=await transactions.save_transaction(request(),data(),db)
                assert first['status']=='success'
            async with factory() as db:
                second=await transactions.save_transaction(request(),data(),db)
                assert second['action']=='unchanged'
                assert first['serial']==second['serial']
            assert len(attempts)==1
        finally:await engine.dispose()
    asyncio.run(work())


@pytest.mark.parametrize('scenario',['missing','committed','deleted','other-owner','rights-revoked','branch-revoked','moved-out-of-scope'])
def test_status_checks_only_report_the_authenticated_owners_result(scenario,tmp_path,monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(transactions.manager,'broadcast',quiet)
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'journal.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
        try:
            if scenario!='missing':
                async with factory() as db:
                    await transactions.save_transaction(request(),data(),db)
                    if scenario in {'deleted','moved-out-of-scope'}:
                        row=await db.scalar(select(models.Transaction))
                        if scenario=='deleted':row.is_deleted=True
                        else:row.branch_code='B3'
                        await db.commit()
            actor=request()
            expected=404 if scenario=='missing' else None
            if scenario=='other-owner':actor=request(uid='other');expected=403
            if scenario=='rights-revoked':actor=request(rights={'المعاينة':True});expected=403
            if scenario=='branch-revoked':actor=request(branches=['B2']);expected=403
            async with factory() as db:
                if expected:
                    with pytest.raises(HTTPException) as error:
                        await transactions.journal_save_status(actor,'C1',KEY,branch_code='B1',db=db)
                    assert error.value.status_code==expected
                else:
                    result=await transactions.journal_save_status(actor,'C1',KEY,branch_code='B1',db=db)
                    assert result['committed'] is True
                    assert result['available']==(scenario=='committed')
                    if scenario!='committed':assert result['record'] is None
                    assert result['serial']==1
        finally:await engine.dispose()
    asyncio.run(work())
